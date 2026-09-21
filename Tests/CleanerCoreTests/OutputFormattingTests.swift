import Testing
import Foundation
@testable import CleanerCore

// Everything the `devcleaner` binary prints, and every decision it makes about what the
// user asked for, is built by a function in `CleanerCore`. That is what makes this file
// possible: an executable target cannot be imported by a test target, so a sentence written
// inline in `main.swift` could only be checked by running the binary — and the one path
// that removes data must never be run here.

private let testHome = "/Users/tester"
private let report = ReportText(home: testHome)

private func item(
    id: String = "row.1",
    scanner: String = "other.libraryCaches",
    group: GroupID = .otherCaches,
    name: String = "row",
    detail: String? = nil,
    size: Int64 = 1_000,
    risk: RiskLevel = .safe,
    protection: ProtectionReason? = nil,
    method: DeletionMethod = .removePath("/Users/tester/Library/Caches/thing"),
    startsUnticked: Bool = false,
    sizeMayBeShared: Bool = false,
    untickedReason: ProtectionReason? = nil
) -> CleanupItem {
    CleanupItem(
        id: id, scannerID: scanner, group: group, name: name, detail: detail,
        sizeBytes: size, lastUsed: nil, risk: risk, protection: protection, method: method,
        startsUnticked: startsUnticked, sizeMayBeShared: sizeMayBeShared,
        untickedReason: untickedReason)
}

private func scanResult(
    _ items: [CleanupItem],
    generatedAt: Date = Date(timeIntervalSince1970: 1_786_000_000),
    availableBytes: Int64 = 292_400_000_000,
    skipped: [String] = [],
    ignoredRoots: [String] = []
) -> ScanResult {
    ScanResult(items: items, generatedAt: generatedAt, availableBytes: availableBytes,
               skippedScannerIDs: skipped, ignoredProjectRoots: ignoredRoots)
}

private func entry(
    id: String = "e", name: String = "thing", target: String = "/Users/tester/x",
    size: Int64 = 1_000, outcome: ItemOutcome, trashedTo: String? = nil,
    reason: String? = nil
) -> RunEntry {
    RunEntry(itemID: id, name: name, target: target, sizeBytes: size,
             outcome: outcome, trashedTo: trashedTo, reason: reason)
}

private func runRecord(
    _ entries: [RunEntry], before: Int64 = 100_000_000_000, after: Int64 = 100_000_000_000,
    notes: [String] = []
) -> RunRecord {
    RunRecord(
        startedAt: Date(timeIntervalSince1970: 1_786_000_000),
        finishedAt: Date(timeIntervalSince1970: 1_786_000_060),
        availableBytesBefore: before, availableBytesAfter: after,
        entries: entries, notes: notes)
}

// MARK: - the two formatters the plan pinned

@Test func formatsBytesWithOneDecimalAboveAGigabyte() {
    #expect(ByteText.short(25_000_000_000) == "25.0 GB")
    #expect(ByteText.short(2_540_000_000) == "2.5 GB")
    #expect(ByteText.short(916_000) == "916 KB")
    #expect(ByteText.short(0) == "0 KB")
}

/// The same size written in another size's scale, for the one place two of them are printed as
/// a single quantity — the deck's "0.6 of 41.3 GB".
///
/// Same table as `short`, which is the whole reason it lives here: the divisors and the
/// decimals have to be the ones the total above it was rounded by. A negative or a zero
/// reference falls to kilobytes exactly as `short` does for such a size.
@Test func formatsBytesInTheScaleAnotherSizeWouldUse() {
    #expect(ByteText.short(582_000_000, inTheScaleOf: 41_300_000_000) == "0.6 GB")
    #expect(ByteText.short(3_800_000_000, inTheScaleOf: 41_300_000_000) == "3.8 GB")
    // Whole megabytes in a megabyte page, whole kilobytes in a kilobyte one: the decimals
    // are the scale's, not the caller's.
    #expect(ByteText.short(120_000_000, inTheScaleOf: 640_000_000) == "120 MB")
    #expect(ByteText.short(4_000, inTheScaleOf: 40_000) == "4 KB")
    // A reference in its own scale is the same string `short` would have written on its own.
    #expect(ByteText.short(2_540_000_000, inTheScaleOf: 2_540_000_000)
            == ByteText.short(2_540_000_000))
    // Clamped in both arguments, like every other size in this app.
    #expect(ByteText.short(-5_000_000, inTheScaleOf: 41_300_000_000) == "0.0 GB")
    #expect(ByteText.short(916_000, inTheScaleOf: -1) == "916 KB")
}

@Test func formatsScanAge() {
    let now = Date(timeIntervalSince1970: 1_786_000_000)
    #expect(AgeText.since(now.addingTimeInterval(-30), now: now) == "just now")
    #expect(AgeText.since(now.addingTimeInterval(-3_600 * 2), now: now) == "2h ago")
    #expect(AgeText.since(now.addingTimeInterval(-86_400 * 3), now: now) == "3d ago")
}

@Test func ageIsMeasuredAgainstTheSuppliedTimeAndNeverTheWallClock() {
    // A pinned `now` a decade before the real one. A wall-clock read would say "d ago"
    // with a five-figure day count instead.
    let now = Date(timeIntervalSince1970: 1_600_000_000)
    #expect(AgeText.since(now.addingTimeInterval(-60 * 45), now: now) == "45m ago")
}

@Test func aSizeIsNeverNegativeButTheFreeSpaceChangeCanBe() {
    // `ByteText.short` clamps, which is right for a size.
    #expect(ByteText.short(-5_000_000) == "0 KB")
    // The free-space change is not a size. A run that left the disk busier has to say so,
    // not print "0 KB" and look like it did nothing.
    #expect(ReportText.signed(-5_000_000) == "-5 MB")
    #expect(ReportText.signed(5_000_000) == "5 MB")
    #expect(ReportText.signed(0) == "0 KB")
}

// MARK: - the tick rule

@Test func theRowMarkComesFromSelectedByDefaultAndNeverFromIsDeletable() {
    // Deletable, ticked.
    #expect(ReportText.mark(for: item()) == "x")
    // Deletable, ticked, higher risk.
    #expect(ReportText.mark(for: item(risk: .elevated)) == "!")
    // Deletable and deliberately NOT ticked — the Android NDK. `isDeletable` is true here,
    // so a mark read from it would say "x" and promise a removal that will not happen.
    #expect(ReportText.mark(for: item(startsUnticked: true)) == " ")
    #expect(ReportText.mark(for: item(risk: .elevated, startsUnticked: true)) == " ")
    // Protected: shown, never ticked.
    #expect(ReportText.mark(for: item(protection: .pinnedProject)) == "-")
    // Offered with a reason to think about it — an active project's build folder. Its box
    // is empty like the NDK's, and emphatically **not** a `-`: the row is deletable, and
    // `[-]` in the legend means "kept, cannot be removed", which would be a lie the user
    // acts on by never ticking it.
    #expect(ReportText.mark(
        for: item(startsUnticked: true, untickedReason: .recentActivity(days: 14))) == " ")
}

/// The listing of a project the user is working in: offered, with its real size, box
/// empty, and the reason printed beside the folder's name.
///
/// The `devcleaner` listing is one line per folder with a tick box two columns to the left,
/// and it is the only surface with nowhere else to put the reason. Without it the user
/// reads "946 MB .build" with an empty box and the same note the NDK gets — "a default
/// clean leaves it alone" — and nothing anywhere says the project is one they were working
/// in yesterday.
@Test func theListingSaysWhyAnActiveProjectsFolderIsOfferedUnticked() {
    let active = item(
        id: "projects.buildOutput|/Users/tester/dev/Sample Game/.build",
        scanner: "projects.buildOutput", group: .projects, name: ".build",
        detail: "Sample Game · changed in the last 14 days",
        size: 946_000_000,
        method: .removePath("/Users/tester/dev/Sample Game/.build"),
        startsUnticked: true, untickedReason: .recentActivity(days: 14))
    let text = report.scan(scanResult([active]),
                           now: Date(timeIntervalSince1970: 1_786_000_000), moveToTrash: true)

    #expect(text.contains("  [ ]    946 MB  .build  "
        + "(Sample Game · changed in the last 14 days)"))
    #expect(!text.contains("  [x]    946 MB  .build"))
    #expect(!text.contains("  [-]    946 MB  .build"))
    // The note still reads right: it is offered, it is not ticked, and a default clean
    // really does leave it alone.
    #expect(text.contains(ReportText.untickedNote))
    #expect(text.contains("Ticked by default:    up to 0 KB"))
    #expect(text.contains("Offered, not ticked:  946 MB"))
    // …and never as a kept row, which is the reading the old behaviour would have printed.
    #expect(!text.contains("[kept:"))
}

@Test func theListingLeavesTheNDKUntickedAndSaysWhatThatMeans() {
    let ndk = item(
        id: "android.ndk:/Users/tester/Library/Android/sdk/ndk/28.2.13676358",
        scanner: "android.ndk", group: .android, name: "28.2.13676358",
        size: 2_980_000_000,
        method: .removePath("/Users/tester/Library/Android/sdk/ndk/28.2.13676358"),
        startsUnticked: true)
    let text = report.scan(scanResult([ndk]),
                           now: Date(timeIntervalSince1970: 1_786_000_000), moveToTrash: true)

    // The row is offered, with its size, and its box is empty. A mark read from
    // `isDeletable` would put an `x` there and promise a removal that will not happen.
    #expect(text.contains("  [ ]    3.0 GB  28.2.13676358"))
    #expect(!text.contains("  [x]    3.0 GB  28.2.13676358"))
    #expect(text.contains(ReportText.untickedNote))
    // …and it is in neither the group total nor the headline.
    #expect(text.contains("Android  —  0 KB ticked, 1 row"))
    #expect(text.contains("Ticked by default:    up to 0 KB"))
    #expect(text.contains("Offered, not ticked:  3.0 GB"))
    // …nor in the Trash/permanent split under it, which is built from a **second** read
    // of the selection and had no test of its own. Replacing `result.defaultSelection`
    // there with `result.items.filter(\.isDeletable)` left the whole suite passing, and
    // the real scan then printed "to the Trash: 45.7 GB across 50 rows" under a headline
    // of "up to 58.0 GB" and directly above "Offered, not ticked: 5.6 GB" — three numbers
    // on one screen that cannot all be true.
    #expect(text.contains("to the Trash:       0 KB across 0 rows"))
    #expect(text.contains("permanently:        0 KB across 0 rows"))
}

/// The over-fix guard for the split above: a row that really is ticked really does appear
/// in it, on the correct side. A split hard-coded to nothing would pass the test above.
@Test func theScanFooterSplitsTheTickedRowsIntoTrashAndPermanent() {
    let cache = item(id: "cache", name: "DerivedData", size: 12_000_000_000,
                     method: .removePath("/Users/tester/Library/Developer/Xcode/DerivedData"))
    let simulator = item(id: "sim", scanner: "ios.simulators", group: .xcodeAndIOS,
                         name: "iPhone 17", size: 3_000_000_000,
                         method: .deleteSimulator(udid: "AAA"))
    let ndk = item(id: "ndk", scanner: "android.ndk", group: .android, name: "28.2.13676358",
                   size: 2_980_000_000,
                   method: .removePath("/Users/tester/Library/Android/sdk/ndk/28.2.13676358"),
                   startsUnticked: true)
    let text = report.scan(scanResult([cache, simulator, ndk]),
                           now: Date(timeIntervalSince1970: 1_786_000_000), moveToTrash: true)

    #expect(text.contains("to the Trash:       12.0 GB across 1 rows"))
    #expect(text.contains("permanently:        3.0 GB across 1 rows"))
    // The unticked NDK is in neither side, and its 3.0 GB is reported separately.
    #expect(text.contains("Offered, not ticked:  3.0 GB"))
}

@Test func aPlanBuiltFromTheDefaultSelectionLeavesTheUntickedRowOut() {
    let ndk = item(id: "ndk", name: "28.2.13676358", size: 2_980_000_000,
                   method: .removePath("/Users/tester/Library/Android/sdk/ndk/28.2.13676358"),
                   startsUnticked: true)
    let cache = item(id: "cache", name: "DerivedData", size: 12_000_000_000,
                     method: .removePath("/Users/tester/Library/Developer/Xcode/DerivedData"))
    let result = scanResult([ndk, cache])

    #expect(result.defaultSelection.count == 1)
    let text = report.plan(items: result.defaultSelection, warnings: [], moveToTrash: true)
    #expect(text.contains("DerivedData"))
    #expect(!text.contains("28.2.13676358"))
}

// MARK: - the headline is an upper bound, never a promise

@Test func theHeadlineSaysUpToAndGivesARangeWhenSomeBytesMayBeShared() {
    let pnpm = item(id: "pnpm", name: "pnpm store", size: 1_826_402_304,
                    method: .removePath("/Users/tester/Library/pnpm/store"),
                    sizeMayBeShared: true)
    let plain = item(id: "plain", name: "Yarn", size: 56_161_267_712,
                     method: .removePath("/Users/tester/Library/Caches/Yarn"))
    let line = ReportText.headline(scanResult([pnpm, plain]))

    #expect(line.hasPrefix("up to "))
    #expect(line.contains("58.0 GB"))   // the top of the range
    #expect(line.contains("56.2 GB"))   // the bottom, once the shared part is taken off
    #expect(line.contains("1.8 GB"))    // the part that may be shared
    #expect(line.contains("may be shared with files that are staying"))
}

@Test func theHeadlineIsASingleUpperBoundWhenNothingMayBeShared() {
    let line = ReportText.headline(scanResult([item(size: 4_000_000_000)]))
    #expect(line == "up to 4.0 GB")
}

@Test func nothingInTheScanReportPromisesThatSpaceWillBeFreed() {
    let text = report.scan(
        scanResult([item(size: 4_000_000_000), item(id: "b", size: 1_000_000_000,
                                                    method: .removePath("/Users/tester/Library/pnpm/store"),
                                                    sizeMayBeShared: true)]),
        now: Date(timeIntervalSince1970: 1_786_000_000), moveToTrash: true)

    #expect(text.contains("Ticked by default:    up to "))
    #expect(!text.lowercased().contains("will be freed"))
    #expect(!text.lowercased().contains("will free"))
    // "Free space now" is the measured figure and is a different line from the headline.
    #expect(text.contains("Free space now:       292.4 GB"))
}

// MARK: - three quantities, never merged

@Test func theScanFooterSplitsTheTickedTotalIntoRestorableAndPermanent() {
    let cache = item(id: "cache", group: .xcodeAndIOS, name: "DerivedData", size: 40_000_000_000,
                     method: .removePath("/Users/tester/Library/Developer/Xcode/DerivedData/App"))
    let avd = item(id: "avd", group: .android, name: "sample_emulator_1", size: 9_190_000_000,
                   method: .deleteAVD(name: "sample_emulator_1"))
    let text = report.scan(scanResult([cache, avd]),
                           now: Date(timeIntervalSince1970: 1_786_000_000), moveToTrash: true)

    #expect(text.contains("  to the Trash:       40.0 GB across 1 rows"))
    #expect(text.contains("  permanently:        9.2 GB across 1 rows"))
    #expect(text.contains("no Trash, no undo"))
}

@Test func inPermanentModeNothingIsShownAsGoingToTheTrash() {
    let cache = item(id: "cache", name: "DerivedData", size: 40_000_000_000,
                     method: .removePath("/Users/tester/Library/Developer/Xcode/DerivedData/App"))
    let split = RemovalSplit(items: [cache], moveToTrash: false)

    #expect(split.toTrash.isEmpty)
    #expect(split.trashBytes == 0)
    #expect(split.permanent.count == 1)
    let permanentBytes = split.permanentBytes
    #expect(permanentBytes == Int64(40_000_000_000))
}

@Test func aDeviceIsPermanentEvenInTrashMode() {
    let avd = item(id: "avd", name: "sample_emulator_1", size: 9_190_000_000,
                   method: .deleteAVD(name: "sample_emulator_1"))
    let simulator = item(id: "sim", name: "sample-ios-simulator", size: 3_690_000_000,
                         method: .deleteSimulator(udid: "UDID-1"))
    let runtime = item(id: "rt", name: "iOS 18.0", size: 8_000_000_000,
                       method: .deleteSimulatorRuntime(identifier: "com.apple.iOS-18-0"))
    let split = RemovalSplit(items: [avd, simulator, runtime], moveToTrash: true)

    #expect(split.toTrash.isEmpty)
    #expect(split.permanent.count == 3)
}

@Test func aSplitCountsOneDeletionTargetOnce() {
    // Two rows naming one directory are one lot of bytes on disk.
    let first = item(id: "a", size: 1_000_000_000,
                     method: .removePath("/Users/tester/Library/Caches/same"))
    let second = item(id: "b", size: 1_000_000_000,
                      method: .removePath("/Users/tester/Library/Caches/same"))
    let split = RemovalSplit(items: [first, second], moveToTrash: true)
    let trashBytes = split.trashBytes
    #expect(trashBytes == Int64(1_000_000_000))
}

@Test func theRunReportKeepsTrashedPermanentAndFreeSpaceApart() {
    // The measured run from the plan: 6.15 GB trashed, and 60 MB of free space gained,
    // because the Trash still holds the rest.
    let record = runRecord(
        [entry(name: "DerivedData", size: 6_150_000_000, outcome: .trashed,
               trashedTo: "/Users/tester/.Trash/DerivedData"),
         entry(id: "d", name: "sample_emulator_1", target: "sample_emulator_1",
               size: 9_190_000_000, outcome: .deleted)],
        before: 100_000_000_000, after: 100_060_000_000)
    let text = report.run(record)

    #expect(text.contains("Moved to Trash:       6.2 GB (1 items)"))
    #expect(text.contains("Permanently deleted:  9.2 GB (1 items"))
    #expect(text.contains("Free space change:    60 MB"))
    // The three are never added into one figure.
    #expect(!text.contains("Freed:"))
    #expect(!text.contains("Total freed"))
    #expect(text.contains("Trashing moves bytes; it does not release them."))
}

@Test func aRunThatLeftTheDiskBusierSaysSoRatherThanPrintingZero() {
    let record = runRecord([entry(outcome: .trashed, trashedTo: "/Users/tester/.Trash/x")],
                           before: 100_000_000_000, after: 99_950_000_000)
    #expect(report.run(record).contains("Free space change:    -50 MB"))
}

@Test func theRunReportTellsTheUserTheTrashStillHoldsTheSpace() {
    let record = runRecord([entry(size: 6_150_000_000, outcome: .trashed,
                                  trashedTo: "/Users/tester/.Trash/DerivedData")])
    #expect(report.run(record).contains(
        "Empty the Trash to actually free the 6.2 GB it now holds."))
}

@Test func aRunThatTrashedNothingDoesNotTalkAboutTheTrash() {
    let record = runRecord([entry(name: "sample_emulator_1", target: "sample_emulator_1",
                                  size: 9_190_000_000, outcome: .deleted)])
    #expect(!report.run(record).contains("Empty the Trash"))
}

// MARK: - where things went, and why they did not

@Test func theRunReportSaysWhereEachTrashedItemLanded() {
    let record = runRecord([
        entry(name: "DerivedData", target: "/Users/tester/Library/Developer/Xcode/DerivedData",
              size: 6_150_000_000, outcome: .trashed,
              trashedTo: "/Users/tester/.Trash/DerivedData"),
        entry(id: "b", name: "Yarn", target: "/Users/tester/Library/Caches/Yarn",
              size: 2_000_000_000, outcome: .trashed,
              trashedTo: "/Users/tester/.Trash/Yarn"),
    ])
    let text = report.run(record)

    #expect(text.contains("Moved to the Trash — you can drag these back:"))
    #expect(text.contains("~/.Trash/DerivedData"))
    #expect(text.contains("~/.Trash/Yarn"))
}

@Test func theRunReportListsEveryPermanentlyDeletedRowByName() {
    let record = runRecord([
        entry(name: "sample_emulator_1", target: "sample_emulator_1", size: 9_190_000_000,
              outcome: .deleted),
        entry(id: "b", name: "sample-ios-simulator", target: "UDID-1", size: 3_690_000_000,
              outcome: .deleted),
    ])
    let text = report.run(record)

    #expect(text.contains("Removed permanently — these cannot be got back:"))
    #expect(text.contains("sample_emulator_1"))
    #expect(text.contains("UDID-1"))
}

@Test func theRunReportPrintsTheReasonASkippedEmulatorCarries() {
    let reason = "adb could not be run at /Users/tester/Library/Android/sdk/platform-tools/adb "
        + "(No such file or directory), so it is not known whether this emulator is running; "
        + "removing one cannot be undone, so it was left alone"
    let record = runRecord([entry(name: "sample_emulator_1", target: "sample_emulator_1",
                                  size: 9_190_000_000, outcome: .skipped, reason: reason)])
    let text = report.run(record)

    // A bare "Skipped: 1" is nothing the user can act on. The reason names the adb path,
    // which is the thing to fix before running again.
    #expect(text.contains("skipped: sample_emulator_1 — "))
    #expect(text.contains("platform-tools/adb"))
    #expect(text.contains("Skipped: 1"))
}

@Test func theRunReportPrintsWhyARowFailed() {
    let record = runRecord([entry(name: "build", outcome: .failed,
                                  reason: "refused: it is protected (pinned)")])
    let text = report.run(record)
    #expect(text.contains("failed: build — refused: it is protected (pinned)"))
    #expect(text.contains("Failed: 1"))
}

@Test func aRowWithNoReasonSaysSoRatherThanShowingAnEmptyLine() {
    let record = runRecord([entry(name: "build", outcome: .skipped)])
    #expect(report.run(record).contains("skipped: build — no reason given"))
}

@Test func theRunReportRepeatsTheNoteThatDevicesAreGoneForGood() {
    let record = runRecord([entry(name: "sample_emulator_1", target: "sample_emulator_1",
                                  outcome: .deleted)],
                           notes: [Executor.Note.devicesWereRemovedPermanently])
    #expect(report.run(record).contains("note: " + Executor.Note.devicesWereRemovedPermanently))
}

// MARK: - two rows that look identical

@Test func twoProtectedProjectsOfTheSameNameAreToldApartByTheirPath() {
    // Both model distinct real-world paths: same name, same size, same detail text.
    let first = item(
        id: "projects.buildOutput:/Users/tester/dev/workspace-one/shared-project-name",
        group: .projects, name: "shared-project-name", detail: "changed in the last 14 days",
        size: 13_600_000, protection: .recentActivity(days: 14),
        method: .removePath("/Users/tester/dev/workspace-one/shared-project-name"))
    let second = item(
        id: "projects.buildOutput:/Users/tester/dev/workspace-two/client-app/shared-project-name",
        group: .projects, name: "shared-project-name", detail: "changed in the last 14 days",
        size: 13_600_000, protection: .recentActivity(days: 14),
        method: .removePath("/Users/tester/dev/workspace-two/client-app/shared-project-name"))
    let text = report.scan(scanResult([first, second]),
                           now: Date(timeIntervalSince1970: 1_786_000_000), moveToTrash: true)

    #expect(text.contains("~/dev/workspace-one/shared-project-name"))
    #expect(text.contains("~/dev/workspace-two/client-app/shared-project-name"))
}

@Test func aDeviceRowNamesItsTargetAndSaysRemovalIsPermanent() {
    #expect(report.targetLine(item(method: .deleteAVD(name: "sample_emulator_1")))
        == "emulator sample_emulator_1 · " + ReportText.permanentNote)
    #expect(report.targetLine(item(method: .deleteSimulator(udid: "UDID-1")))
        == "simulator UDID-1 · " + ReportText.permanentNote)
    #expect(report.targetLine(item(method: .deleteSimulatorRuntime(identifier: "iOS-18-0")))
        == "runtime iOS-18-0 · " + ReportText.permanentNote)
    // A path row goes to the Trash, so it must not carry the permanence sentence.
    #expect(!report.targetLine(item()).contains(ReportText.permanentNote))
    // Nor may a device that is being kept: nothing happens to it, and a row already
    // marked "kept" must not also read as a warning that it is about to be destroyed.
    let kept = item(protection: .recentlyUsedDevice(days: 7),
                    method: .deleteSimulator(udid: "UDID-KEPT"))
    #expect(report.targetLine(kept) == "simulator UDID-KEPT")
}

@Test func aRowWhoseSizeMayBeSharedSaysThatOnTheRowItself() {
    let line = report.targetLine(item(method: .removePath("/Users/tester/Library/pnpm/store"),
                                      sizeMayBeShared: true))
    #expect(line.contains("~/Library/pnpm/store"))
    #expect(line.contains(ReportText.sharedNote))
}

@Test func aZeroByteRowIsStillListedWithItsSize() {
    // `ios.simulatorCaches` offers exactly this today.
    let empty = item(id: "ios.simulatorCaches:/Users/tester/Library/Developer/CoreSimulator/Caches",
                     group: .xcodeAndIOS, name: "Caches", size: 0,
                     method: .removePath("/Users/tester/Library/Developer/CoreSimulator/Caches"))
    let text = report.scan(scanResult([empty]),
                           now: Date(timeIntervalSince1970: 1_786_000_000), moveToTrash: true)
    #expect(text.contains("0 KB"))
    #expect(text.contains("~/Library/Developer/CoreSimulator/Caches"))
}

@Test func theTildeAbbreviationNeedsTheSeparator() {
    #expect(report.abbreviate("/Users/tester/dev/app") == "~/dev/app")
    #expect(report.abbreviate("/Users/tester") == "~")
    // A different user whose name starts with the same letters must not be abbreviated.
    #expect(report.abbreviate("/Users/testerson/dev") == "/Users/testerson/dev")
    #expect(report.abbreviate("/opt/homebrew") == "/opt/homebrew")
}

// MARK: - the plan, shown before anything happens

@Test func thePlanSaysDeviceRemovalIsPermanentBeforeAnythingHappens() {
    let avd = item(id: "avd", name: "sample_emulator_1", size: 9_190_000_000,
                   method: .deleteAVD(name: "sample_emulator_1"))
    let warnings = CleanerService.warnings(for: [avd], moveToTrash: true)
    let text = report.plan(items: [avd], warnings: warnings, moveToTrash: true)

    #expect(text.contains(CleanerService.Warning.devicesAreRemovedPermanently))
    // "normally", not "always": the avdmanager-missing fallback really does use the Trash.
    #expect(text.contains("normally removed permanently"))
}

@Test func thePlanSplitsTheListIntoWhatCanBeGotBackAndWhatCannot() {
    let cache = item(id: "cache", name: "DerivedData", size: 40_000_000_000,
                     method: .removePath("/Users/tester/Library/Developer/Xcode/DerivedData/App"))
    let avd = item(id: "avd", name: "sample_emulator_1", size: 9_190_000_000,
                   method: .deleteAVD(name: "sample_emulator_1"))
    let text = report.plan(items: [cache, avd], warnings: [], moveToTrash: true)

    #expect(text.contains("To the Trash, restorable until you empty it — 1 rows, 40.0 GB:"))
    #expect(text.contains("Removed permanently, no Trash and no undo — 1 rows, 9.2 GB:"))
    #expect(text.contains("DerivedData — ~/Library/Developer/Xcode/DerivedData/App"))
    #expect(text.contains("sample_emulator_1 — emulator sample_emulator_1"))
    #expect(text.contains("2 rows selected, up to 49.2 GB."))
}

@Test func thePermanentSideOfThePlanNamesTheDeviceAndNotOnlyItsIdentifier() {
    // The permanent list is the one worth reading twice, and
    // `00000000-0000-4000-8000-000000000001` alone says nothing about which simulator is
    // about to be destroyed.
    let simulator = item(id: "sim", name: "sample-ios-simulator", size: 3_690_000_000,
                         method: .deleteSimulator(udid: "00000000-0000-4000-8000-000000000001"))
    let text = report.plan(items: [simulator], warnings: [], moveToTrash: true)
    #expect(text.contains("sample-ios-simulator — simulator 00000000-0000-4000-8000-000000000001"))
}

@Test func aRowWhoseSizeMayBeSharedCarriesTheCaveatIntoThePlan() {
    let pnpm = item(id: "pnpm", name: "pnpm store", size: 367_100_000,
                    method: .removePath("/Users/tester/Library/pnpm/store"),
                    sizeMayBeShared: true)
    let text = report.plan(items: [pnpm], warnings: [], moveToTrash: true)
    #expect(text.contains("pnpm store — ~/Library/pnpm/store · " + ReportText.sharedNote))
}

@Test func anEmptySideOfThePlanSaysNoneRatherThanNothing() {
    let cache = item(id: "cache", name: "DerivedData", size: 40_000_000_000,
                     method: .removePath("/Users/tester/Library/Developer/Xcode/DerivedData/App"))
    let text = report.plan(items: [cache], warnings: [], moveToTrash: true)
    #expect(text.contains("Removed permanently, no Trash and no undo — 0 rows, 0 KB:\n  none"))
}

// MARK: - protect

@Test func theProtectionSummaryListsEveryProtectedDeviceAndNotOnlyTheKeptOne() {
    // Three simulators survive a default clean; only one is labelled "kept". Printing the
    // singular field alone would tell the user the other two are unprotected.
    let set = ProtectionSet(
        projects: [:],
        keptSimulatorUDID: "UDID-NEWEST", keptAVDName: "sample_emulator",
        protectedSimulatorUDIDs: [
            "UDID-NEWEST": .mostRecentlyUsedDevice,
            "UDID-YESTERDAY": .recentlyUsedDevice(days: 7),
            "UDID-PINNED": .pinnedDevice,
        ],
        protectedAVDNames: ["sample_emulator": .mostRecentlyUsedDevice],
        flutterVersions: ["3.38.5": .sdkInUse(by: "bull-report-flutter")],
        gradleDistributions: ["gradle-8.12-all": .gradleVersionInUse(by: "sample-app")],
        runtimeIdentifiers: ["com.apple.CoreSimulator.SimRuntime.iOS-26-0": .newestRuntime])
    let text = report.protection(set)

    #expect(text.contains("Protected simulators (3):"))
    #expect(text.contains("UDID-NEWEST — most recently used"))
    #expect(text.contains("UDID-YESTERDAY — used in the last 7 days"))
    #expect(text.contains("UDID-PINNED — pinned"))
    #expect(text.contains("labelled as the one kept: UDID-NEWEST"))
    #expect(text.contains("sample_emulator — most recently used"))
    #expect(text.contains("3.38.5 — used by bull-report-flutter"))
    #expect(text.contains("gradle-8.12-all — used by sample-app"))
    #expect(text.contains("com.apple.CoreSimulator.SimRuntime.iOS-26-0 — newest installed runtime"))
}

@Test func theProtectionSummaryTellsTwoProjectsOfOneNameApartByPath() {
    let set = ProtectionSet(
        projects: [
            "/Users/tester/dev/workspace-one/shared-project-name": .recentActivity(days: 14),
            "/Users/tester/dev/workspace-two/client-app/shared-project-name": .recentActivity(days: 14),
        ],
        keptSimulatorUDID: nil, keptAVDName: nil,
        protectedSimulatorUDIDs: [:], protectedAVDNames: [:],
        flutterVersions: [:], gradleDistributions: [:], runtimeIdentifiers: [:])
    let text = report.protection(set)

    #expect(text.contains("Protected projects (2)"))
    #expect(text.contains("~/dev/workspace-one/shared-project-name — changed in the last 14 days"))
    #expect(text.contains("~/dev/workspace-two/client-app/shared-project-name — changed in the last 14 days"))
}

@Test func anEmptyProtectionSummarySaysNoneEverywhere() {
    let text = report.protection(.empty)
    #expect(text.contains("Protected projects (0)"))
    #expect(text.contains("labelled as the one kept: none"))
}

// MARK: - the destructive gate: arguments

@Test func theParserOnlyTreatsTheExactDryRunFlagAsARehearsal() {
    #expect(CLIParser.parse(["clean", "--dry-run"]) == .dryRun)
    #expect(CLIParser.parse(["clean"]) == .clean)
    // One missing hyphen. Matching with `arguments.contains("--dry-run")` would make each
    // of these a REAL clean that the user believed was a rehearsal.
    for typo in ["--dryrun", "--dry_run", "-dry-run", "--dry-run=true", "dry-run"] {
        guard case .invalid = CLIParser.parse(["clean", typo]) else {
            Issue.record("clean \(typo) was not refused")
            continue
        }
    }
    // …and it must not have been read as a clean either.
    #expect(CLIParser.parse(["clean", "--dryrun"]) != .clean)
}

@Test func theParserRefusesAnythingItDoesNotFullyUnderstand() {
    guard case .invalid(let unknown) = CLIParser.parse(["clena"]) else {
        Issue.record("an unknown command was accepted"); return
    }
    #expect(unknown.contains("clena"))

    guard case .invalid = CLIParser.parse(["scan", "--all"]) else {
        Issue.record("an option after scan was accepted"); return
    }
    guard case .invalid = CLIParser.parse(["protect", "extra"]) else {
        Issue.record("an argument after protect was accepted"); return
    }
    guard case .invalid = CLIParser.parse(["clean", "--dry-run", "--force"]) else {
        Issue.record("an extra option after --dry-run was accepted"); return
    }
    // A bare flag is not a command.
    guard case .invalid = CLIParser.parse(["--dry-run"]) else {
        Issue.record("a bare --dry-run was accepted"); return
    }
}

@Test func noArgumentsAsksForTheUsageAndRemovesNothing() {
    #expect(CLIParser.parse([]) == .usage)
    #expect(CLIParser.parse(["help"]) == .usage)
    #expect(CLIParser.parse(["--help"]) == .usage)
    #expect(CLIParser.parse(["-h"]) == .usage)
    #expect(CLIParser.parse(["scan"]) == .scan)
    #expect(CLIParser.parse(["protect"]) == .protect)
}

@Test func theUsageSaysWhichCommandRemovesThingsAndWhatItAsksFirst() {
    #expect(CLIText.usage.contains("devcleaner scan"))
    #expect(CLIText.usage.contains("devcleaner protect"))
    #expect(CLIText.usage.contains("devcleaner clean --dry-run"))
    #expect(CLIText.usage.contains("Only devcleaner clean removes anything"))
    #expect(CLIText.usage.contains("type clean"))
}

// MARK: - the destructive gate: the typed word

@Test func onlyTheExactWordCleanConfirmsADestructiveRun() {
    #expect(CleanConfirmation.isConfirmed("clean"))
    // Whitespace and the trailing newline a terminal supplies are trimmed.
    #expect(CleanConfirmation.isConfirmed("  clean  "))
    #expect(CleanConfirmation.isConfirmed("clean\n"))

    // The answers a person gives without reading the list.
    #expect(!CleanConfirmation.isConfirmed("y"))
    #expect(!CleanConfirmation.isConfirmed("Y"))
    #expect(!CleanConfirmation.isConfirmed("yes"))
    #expect(!CleanConfirmation.isConfirmed(""))
    #expect(!CleanConfirmation.isConfirmed("   "))
    #expect(!CleanConfirmation.isConfirmed("Clean"))
    #expect(!CleanConfirmation.isConfirmed("CLEAN"))
    #expect(!CleanConfirmation.isConfirmed("cleanup"))
    #expect(!CleanConfirmation.isConfirmed("clean now"))
    // End of input — a pipe that closed, or ctrl-D.
    #expect(!CleanConfirmation.isConfirmed(nil))
}

@Test func theConfirmationTextNamesTheWordAndSaysWhatHappensOtherwise() {
    #expect(CleanConfirmation.prompt.contains(CleanConfirmation.phrase))
    #expect(CleanConfirmation.prompt.contains("Anything else stops."))
    #expect(CleanConfirmation.stopped == "Nothing was removed.")
    #expect(CleanConfirmation.needsATerminal.contains("needs a terminal"))
    #expect(CleanConfirmation.needsATerminal.contains("Nothing was removed."))
}

// MARK: - progress, so a 50 second scan does not look hung

@Test func theProgressLineCountsScannersAndNamesTheOneRunningNow() {
    let line = CLIText.progress(ScanProgress(
        completed: 6, total: 16, currentID: "android.avds", currentTitle: "Android emulators"))
    #expect(line == "  [6/16] Android emulators")

    let running = CLIText.progress(ExecutionProgress(
        completed: 3, total: 57, currentName: "DerivedData"))
    #expect(running == "  [3/57] DerivedData")
}

/// Collects the progress callbacks a scan makes.
///
/// A class with a lock rather than an actor: the callback itself is synchronous, so it
/// cannot `await`, and `NSLock` is only unavailable from an asynchronous context.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [ScanProgress] = []

    func record(_ progress: ScanProgress) {
        lock.lock(); lines.append(progress); lock.unlock()
    }
    var recorded: [ScanProgress] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}

private struct SilentScanner: CleanupScanner {
    let id: String
    let group: GroupID
    let title: String
    func scan(_ context: ScanContext) async -> [CleanupItem] { [] }
}

@Test func theEngineAnnouncesEveryScannerBeforeItRunsIncludingASkippedOne() async throws {
    var settings = Settings.makeDefault(home: testHome)
    settings.alwaysSkipScannerIDs = ["android.avds"]
    let context = ScanContext(
        settings: settings, protection: .empty, projects: [], devices: .empty,
        home: testHome, androidSDKPath: testHome + "/Library/Android/sdk",
        sizeMeasurer: FixedSizeMeasurer([:]), runner: FakeProcessRunner(responses: [:]),
        fileManager: .default, now: Date(timeIntervalSince1970: 1_786_000_000))
    let log = ProgressLog()
    let engine = ScanEngine(scanners: [
        SilentScanner(id: "xcode.derivedData", group: .xcodeAndIOS, title: "DerivedData"),
        SilentScanner(id: "android.avds", group: .android, title: "Android emulators"),
        SilentScanner(id: "other.libraryCaches", group: .otherCaches, title: "Library caches"),
    ])

    _ = await engine.scan(context: context) { log.record($0) }

    let recorded = log.recorded
    #expect(recorded.count == 3)
    let first = try #require(recorded.first)
    #expect(first.completed == 0)
    #expect(first.total == 3)
    #expect(first.currentTitle == "DerivedData")
    // Announced although it is skipped, so the numbers count the same list the settings
    // screen shows and never stall.
    let second = try #require(recorded.dropFirst().first)
    #expect(second.currentID == "android.avds")
    #expect(second.completed == 1)
    let third = try #require(recorded.last)
    #expect(third.completed == 2)
    #expect(third.currentTitle == "Library caches")
}

@Test func aScanWithNoProgressCallbackStillWorks() async {
    let context = ScanContext(
        settings: .makeDefault(home: testHome), protection: .empty, projects: [],
        devices: .empty, home: testHome, androidSDKPath: testHome + "/Library/Android/sdk",
        sizeMeasurer: FixedSizeMeasurer([:]), runner: FakeProcessRunner(responses: [:]),
        fileManager: .default, now: Date(timeIntervalSince1970: 1_786_000_000))
    let result = await ScanEngine(scanners: [
        SilentScanner(id: "xcode.derivedData", group: .xcodeAndIOS, title: "DerivedData"),
    ]).scan(context: context)
    #expect(result.items.isEmpty)
}

// MARK: - the listing as a whole

@Test func theListingReportsWhatTheSettingsSkippedAndWhatWasTooWideToWalk() {
    let text = report.scan(
        scanResult([item()], skipped: ["android.ndk"], ignoredRoots: ["/Users/tester"]),
        now: Date(timeIntervalSince1970: 1_786_000_000), moveToTrash: true)
    #expect(text.contains("Skipped by settings: android.ndk"))
    #expect(text.contains("Project roots ignored, too wide to walk: ~"))
}

@Test func theListingGroupsRowsAndPutsTheBiggestFirst() throws {
    let small = item(id: "small", group: .android, name: "small", size: 1_000_000,
                     method: .removePath("/Users/tester/.gradle/small"))
    let big = item(id: "big", group: .android, name: "big", size: 9_000_000_000,
                   method: .removePath("/Users/tester/.gradle/big"))
    let other = item(id: "other", group: .otherCaches, name: "other", size: 5_000_000,
                     method: .removePath("/Users/tester/Library/Caches/other"))
    let text = report.scan(scanResult([small, big, other]),
                           now: Date(timeIntervalSince1970: 1_786_000_000), moveToTrash: true)

    let bigLine = try #require(text.range(of: "  big"))
    let smallLine = try #require(text.range(of: "  small"))
    #expect(bigLine.lowerBound < smallLine.lowerBound)
    #expect(text.contains("Android  —  9.0 GB ticked, 2 rows"))
    #expect(text.contains("Other caches  —  5 MB ticked, 1 row"))
    // Group order follows `GroupID.allCases`, so Android comes before Other caches.
    let android = try #require(text.range(of: "Android  —"))
    let others = try #require(text.range(of: "Other caches  —"))
    #expect(android.lowerBound < others.lowerBound)
}

// MARK: - the whole round trip, on doubles only

/// Scan, tick, clean and report, through the real `CleanerService` and the real `Executor`,
/// with a temporary directory for a home and doubles for every process and every removal.
///
/// This is the only test here that exercises what the `clean` command actually does. It
/// deletes nothing real: `FakeFileRemover` removes the fixture inside the temporary
/// directory and reports a made-up Trash location, and `RecordingProcessRunner` starts no
/// process — no `simctl`, no `avdmanager`, no `emulator`.
@Test func scanTickCleanAndReportSurviveTheWholeRoundTripOnDoubles() async throws {
    let scanAt = Date(timeIntervalSince1970: 1_786_000_000)
    let temp = TempDir()
    let sdk = temp.path + "/Library/Android/sdk"
    let ndk = temp.makeDirectory("Library/Android/sdk/ndk/27.0.12077973")
    let gradle = temp.makeDirectory(".gradle/caches/build-cache-1")

    var settings = Settings.makeDefault(home: temp.path)
    settings.projectRoots = [temp.path + "/dev"]
    let store = SettingsStore(directory: temp.url, home: temp.path)
    try store.save(settings)

    let service = CleanerService(
        settingsStore: store,
        runLog: RunLog(directory: temp.url.appendingPathComponent("runs")),
        runner: RecordingProcessRunner(),
        remover: FakeFileRemover(),
        sizeMeasurer: FixedSizeMeasurer([ndk: 3_000_000_000, gradle: 2_000_000_000]),
        fileManager: .default,
        home: temp.path,
        androidSDKPath: sdk,
        clock: { Date(timeIntervalSince1970: 1_786_000_042) })
    let text = ReportText(home: temp.path)

    let scanned = await service.scan(now: scanAt)
    let listing = text.scan(scanned, now: scanAt, moveToTrash: true)
    // The NDK is offered, with its size, and its box is empty.
    #expect(listing.contains("  [ ]    3.0 GB  27.0.12077973"))
    #expect(listing.contains("Offered, not ticked:  3.0 GB"))

    let selected = scanned.defaultSelection
    #expect(!selected.contains { $0.scannerID == "android.ndk" })
    let plan = text.plan(items: selected, warnings: service.warnings(for: selected),
                         moveToTrash: true)
    #expect(!plan.contains("27.0.12077973"))

    let record = await service.clean(items: selected, now: scanAt, progress: { _ in })

    // The tick rule surviving the round trip: the NDK is still on disk, the ticked row is
    // not, and the report says so with the trashed bytes kept apart from everything else.
    #expect(FileManager.default.fileExists(atPath: ndk))
    #expect(!FileManager.default.fileExists(atPath: gradle))
    let trashed = record.trashedBytes
    #expect(trashed == Int64(2_000_000_000))

    let reported = text.run(record)
    #expect(reported.contains("Moved to Trash:       2.0 GB"))
    #expect(reported.contains("Permanently deleted:  0 KB"))
    #expect(reported.contains("Free space change:"))
    #expect(reported.contains(".Trash/build-cache-1"))
    #expect(reported.contains("Empty the Trash to actually free the 2.0 GB it now holds."))
}

@Test func theListingSaysItRemovedNothing() {
    let text = report.scan(scanResult([item()]),
                           now: Date(timeIntervalSince1970: 1_786_000_000), moveToTrash: true)
    #expect(text.contains("Nothing has been removed."))
    #expect(text.contains("Legend: [x] will be removed"))
    #expect(text.contains("Scanned:              just now"))
}

// MARK: - one of the user's own files, in the output

/// A row as `big.downloads` builds one.
private func bigThing(
    id: String = "big.downloads|/Users/tester/Downloads/Xcode.xip",
    name: String = "Xcode.xip", size: Int64 = 7_000_000_000
) -> CleanupItem {
    item(id: id, scanner: "big.downloads", group: .bigThings, name: name,
         detail: DownloadsScanner.installerDetail, size: size, risk: .irreplaceable,
         method: .removePath("/Users/tester/Downloads/Xcode.xip"), startsUnticked: true)
}

/// **The split bends in both directions**, and the CLI's plan is the screen that has to be
/// right about it: in permanent mode a cache is removed outright and one of the user's own
/// files still goes to the Trash, because the executor branches on the same function.
@Test func inPermanentModeTheUsersOwnFileStillCountsAsGoingToTheTrash() {
    let cache = item(id: "cache", name: "DerivedData", size: 40_000_000_000,
                     method: .removePath("/Users/tester/Library/Developer/Xcode/DerivedData/App"))
    let split = RemovalSplit(items: [cache, bigThing()], moveToTrash: false)

    #expect(split.toTrash.map(\.name) == ["Xcode.xip"])
    #expect(split.trashBytes == 7_000_000_000)
    #expect(split.permanent.map(\.name) == ["DerivedData"])
    #expect(split.permanentBytes == 40_000_000_000)
    // The same rule, read directly.
    #expect(bigThing().goesToTheTrash(moveToTrash: false))
    #expect(bigThing().goesToTheTrash(moveToTrash: true))
    #expect(!cache.goesToTheTrash(moveToTrash: false))
}

/// And the warning follows it. "The space comes back when you empty it" is exactly as true
/// of a run in permanent mode that moved one of the user's files, and leaving it out would
/// be the one screen where the engine and its own warning disagreed.
@Test func theTrashWarningIsRaisedInPermanentModeByOneOfTheUsersOwnFiles() {
    let cache = item(id: "cache", size: 40_000_000_000,
                     method: .removePath("/Users/tester/Library/Caches/thing"))

    #expect(CleanerService.warnings(for: [cache], moveToTrash: false).isEmpty)
    #expect(CleanerService.warnings(for: [bigThing()], moveToTrash: false)
            == [CleanerService.Warning.trashingDoesNotFreeSpaceYet])
    // A protected row raises nothing: the executor refuses it, so a warning about where it
    // would go is a claim the listing then contradicts.
    let kept = item(id: "kept", scanner: "xcode.deviceSupport", group: .xcodeAndIOS,
                    risk: .irreplaceable, protection: .newestDeviceSupport)
    #expect(CleanerService.warnings(for: [kept], moveToTrash: false).isEmpty)
}

/// The listing has to print the new group and the new risk sensibly, because `devcleaner
/// scan` is the only place a user can read the whole picture at once.
@Test func theListingPrintsTheBigThingsGroupAndSaysWhatTheRowIs() {
    let cache = item(id: "cache", name: "DerivedData", size: 40_000_000_000,
                     method: .removePath("/Users/tester/Library/Developer/Xcode/DerivedData/App"))
    let text = report.scan(scanResult([cache, bigThing()]),
                           now: Date(timeIntervalSince1970: 1_786_000_000), moveToTrash: true)

    #expect(text.contains("Big things  —  0 KB ticked, 1 row"))
    #expect(text.contains("Xcode.xip"))
    // The box is empty, because nothing here is ticked, and the two notes say both halves of
    // the truth: nothing brings it back, and it is not deleted outright either.
    #expect(text.contains("[ ]    7.0 GB  Xcode.xip  (An installer."))
    #expect(text.contains(ReportText.irreplaceableNote))
    #expect(text.contains(ReportText.untickedNote))
    #expect(text.contains("Offered, not ticked:  7.0 GB"))
    #expect(text.contains("Ticked by default:    up to 40.0 GB"))
}

/// The note is guarded like the permanence note: a protected device support folder is never
/// removed, so a sentence about where it would go is a claim the `[-]` beside it contradicts.
@Test func aKeptRowNeverCarriesTheNoteAboutWhereItWouldGo() {
    let kept = item(id: "kept", scanner: "xcode.deviceSupport", group: .xcodeAndIOS,
                    name: "iOS iPhone17,2 27.0 (24A435)", size: 7_000_000_000,
                    risk: .irreplaceable, protection: .newestDeviceSupport,
                    method: .removePath("/Users/tester/Library/Developer/Xcode/x"))

    #expect(ReportText.mark(for: kept) == "-")
    #expect(!report.targetLine(kept).contains(ReportText.irreplaceableNote))
    #expect(report.targetLine(bigThing()).contains(ReportText.irreplaceableNote))
}

/// `mark` reads from `selectedByDefault` and the legend's "higher risk" glyph now covers
/// `.irreplaceable` as well as `.elevated`, so no row that is not plainly safe is ever
/// marked with the plain `x`.
@Test func theBoxGlyphNeverMarksAnythingButAPlainlySafeRowWithAnX() {
    let safe = item(id: "safe")
    let elevated = item(id: "elevated", risk: .elevated)
    // Reachable only by construction — every `.irreplaceable` row a committed scanner
    // builds is unticked — and this is the spelling that stays right if one ever is not.
    let tickedIrreplaceable = item(id: "odd", risk: .irreplaceable)

    #expect(ReportText.mark(for: safe) == "x")
    #expect(ReportText.mark(for: elevated) == "!")
    #expect(ReportText.mark(for: tickedIrreplaceable) == "!")
    #expect(ReportText.mark(for: bigThing()) == " ")
}

// MARK: - large files in the listing

/// A row as `LargeFilesScanner` builds one: the file's name, and the folder it is in.
private func largeFile(
    name: String = "scan.pdf", folder: String = "Documents/archive/scans/batch-a/current",
    size: Int64 = 1_200_000_000
) -> CleanupItem {
    let path = testHome + "/" + folder + "/" + name
    return item(id: "big.largeFiles|" + path, scanner: "big.largeFiles", group: .bigThings,
                name: name, detail: "~/" + folder, size: size, risk: .irreplaceable,
                method: .removePath(path), startsUnticked: true)
}

/// **`devcleaner scan` is the only place a user can read the whole picture at once**, and
/// these rows are the ones it has to be most careful about: they are the user's own files,
/// they are offered, and nothing on any default route will touch them.
///
/// The folder is what the listing has to print. Sixteen sibling folders on the user's Mac
/// each hold a `scan.pdf`, so a listing that printed sixteen identical names and sizes would
/// be unreadable — the abbreviated parent in the detail column and the full target on the
/// line below are between them what tells them apart.
@Test func theListingPrintsALargeFileAsOfferedNotTickedWithTheFolderItIsIn() {
    let cache = item(id: "cache", name: "DerivedData", size: 40_000_000_000,
                     method: .removePath("/Users/tester/Library/Developer/Xcode/DerivedData/App"))
    let text = report.scan(scanResult([cache, largeFile(), largeFile(name: "holiday.mov",
                                                                     folder: "Movies",
                                                                     size: 3_800_000_000)]),
                           now: Date(timeIntervalSince1970: 1_786_000_000), moveToTrash: true)

    // An empty box, the size, the name, and the folder that tells two of them apart.
    #expect(text.contains("[ ]    1.2 GB  scan.pdf  (~/Documents/archive/scans/batch-a/current)"))
    #expect(text.contains("[ ]    3.8 GB  holiday.mov  (~/Movies)"))
    // Both notes, because either alone reads as the whole truth: nothing brings it back,
    // **and** it is not deleted outright, so the Trash really is the way back.
    #expect(text.contains(ReportText.irreplaceableNote))
    #expect(text.contains(ReportText.untickedNote))
    // Never the `mentionOnly` sentence. These rows do have a button — the checklist page's —
    // and telling the reader "devcleaner never removes it" would be false.
    #expect(!text.contains(ReportText.mentionOnlyNote))
    // The numbers: 5.0 GB offered, none of it in the headline.
    #expect(text.contains("Ticked by default:    up to 40.0 GB"))
    #expect(text.contains("Offered, not ticked:  5.0 GB"))
    #expect(text.contains("Big things  —  0 KB ticked, 2 rows"))
}

/// The row's own two lines, read directly, so the exact order of the notes is pinned
/// somewhere the group heading cannot hide a change in.
@Test func aLargeFileRowPrintsItsTargetThenTheTwoThingsTheSizeDoesNotSay() {
    let lines = report.rowLines(largeFile())

    #expect(lines.count == 2)
    #expect(lines[1].contains("~/Documents/archive/scans/batch-a/current/scan.pdf"))
    #expect(report.targetLine(largeFile()) ==
        "~/Documents/archive/scans/batch-a/current/scan.pdf"
        + " · " + ReportText.irreplaceableNote
        + " · " + ReportText.untickedNote)
    // Not the permanence note: that one is for the three device cases, which have no path
    // and no Trash, and saying it here would contradict the sentence beside it.
    #expect(!report.targetLine(largeFile()).contains(ReportText.permanentNote))
    #expect(!report.targetLine(largeFile()).contains(ReportText.sharedNote))
}
