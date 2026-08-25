import Testing
import Foundation
@testable import CleanerCore

private func record(startedAt: Date, entries: [RunEntry] = [],
                    notes: [String] = []) -> RunRecord {
    RunRecord(startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(30),
              availableBytesBefore: 100, availableBytesAfter: 200,
              entries: entries, notes: notes)
}

/// Whole seconds only, everywhere in this file. `JSONEncoder.DateEncodingStrategy
/// .iso8601` writes no fractional part, so a date with one does not survive the round
/// trip and an equality assertion would fail for a reason that has nothing to do with
/// the log. The file name is second-resolution too.
private func time(_ iso: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: iso))
}

/// Writes one file into `<temp>/runs` and returns a log pointed at that directory.
private func logWithRawFile(_ temp: TempDir, named name: String, json: String) -> RunLog {
    temp.makeFile("runs/\(name)", contents: json)
    return RunLog(directory: temp.url.appendingPathComponent("runs"))
}

// MARK: - the brief

@Test func writesARecordThatCanBeReadBack() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    let entry = RunEntry(itemID: "a", name: "build", target: "/dev/x/build",
                         sizeBytes: 500, outcome: .deleted, reason: nil)
    let url = try log.write(record(startedAt: Date(timeIntervalSince1970: 1_786_000_000),
                                   entries: [entry]))

    let loaded = log.load(at: url)
    #expect(loaded?.entries == [entry])
    #expect(loaded?.freeSpaceChangeBytes == 100)
}

@Test func fileNameIsSortableByTime() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    let first = try log.write(record(startedAt: Date(timeIntervalSince1970: 1_786_000_000)))
    let second = try log.write(record(startedAt: Date(timeIntervalSince1970: 1_786_003_600)))
    #expect(first.lastPathComponent < second.lastPathComponent)
}

@Test func keepsOnlyTheNewestTwentyRuns() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    for index in 0..<25 {
        _ = try log.write(record(startedAt: Date(timeIntervalSince1970: 1_786_000_000 + Double(index) * 60)))
    }
    #expect(log.recent(limit: 100).count == 20)
}

/// The brief's `recentReturnsNewestFirst`, rewritten off `recent[0]` and `!` per rule 7:
/// swift-testing has no per-test crash isolation, so an out-of-range trap or a nil
/// force-unwrap here would take every other test's result down with it.
@Test func recentReturnsNewestFirst() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    _ = try log.write(record(startedAt: Date(timeIntervalSince1970: 1_786_000_000)))
    _ = try log.write(record(startedAt: Date(timeIntervalSince1970: 1_786_003_600)))

    let recent = log.recent()
    #expect(recent.count == 2)
    let newestURL = try #require(recent.first)
    let oldestURL = try #require(recent.last)
    let newest = try #require(log.load(at: newestURL))
    let oldest = try #require(log.load(at: oldestURL))

    #expect(newest.startedAt > oldest.startedAt)
    #expect(newest.startedAt == Date(timeIntervalSince1970: 1_786_003_600))
}

@Test func aRunWhereEverythingFailedIsStillWritten() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    let failure = RunEntry(itemID: "a", name: "build", target: "/x",
                           sizeBytes: 0, outcome: .failed, reason: "refused")
    let url = try log.write(record(startedAt: Date(timeIntervalSince1970: 1_786_000_000),
                                   entries: [failure]))
    #expect(log.load(at: url)?.failedCount == 1)
}

@Test func unreadableFileLoadsAsNil() {
    let temp = TempDir()
    temp.makeFile("runs/broken.json", contents: "not json")
    let log = RunLog(directory: temp.url.appendingPathComponent("runs"))
    #expect(log.load(at: temp.url.appendingPathComponent("runs/broken.json")) == nil)
}

// MARK: - what the record has to still say after the app is reopened

/// The net underneath every other assertion here: a written run comes back **whole**.
/// Without this, a field silently dropped on the way out or in — `notes` above all —
/// passes the rest of the file unnoticed.
@Test func everyFieldOfARunSurvivesTheRoundTrip() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    let original = RunRecord(
        startedAt: try time("2026-08-09T13:45:00Z"),
        finishedAt: try time("2026-08-09T13:47:12Z"),
        availableBytesBefore: 41_000_000_000, availableBytesAfter: 53_000_000_000,
        entries: [
            RunEntry(itemID: "xcode.derivedData:/d/App-abc", name: "App-abc",
                     target: "/d/App-abc", sizeBytes: 2_147_483_648, outcome: .trashed,
                     trashedTo: "/Users/tester/.Trash/App-abc"),
            RunEntry(itemID: "ios.simulators:7F1C", name: "iPhone 17", target: "7F1C",
                     sizeBytes: 12_860_000_000, outcome: .deleted),
            RunEntry(itemID: "android.avds:Pixel_9", name: "Pixel_9", target: "Pixel_9",
                     sizeBytes: 0, outcome: .skipped, reason: "the emulator is running"),
        ],
        notes: [Executor.Note.xcodeWasOpen, Executor.Note.devicesWereRemovedPermanently])

    let url = try log.write(original)
    let loaded = try #require(log.load(at: url))
    #expect(loaded == original)
}

/// The reason the log exists. Trashing is only reversible for a user who can find out
/// what was moved and where it went, and after the app is closed this file is the only
/// place either fact is kept.
@Test func aTrashedItemKeepsItsTrashLocationAfterReopening() throws {
    let temp = TempDir()
    let entry = RunEntry(itemID: "other.cocoapods:/Users/tester/Library/Caches/CocoaPods",
                         name: "CocoaPods cache",
                         target: "/Users/tester/Library/Caches/CocoaPods",
                         sizeBytes: 3_221_225_472, outcome: .trashed,
                         trashedTo: "/Users/tester/.Trash/CocoaPods")
    let url = try RunLog(directory: temp.url)
        .write(record(startedAt: try time("2026-08-09T13:45:00Z"), entries: [entry]))

    // A second RunLog, as a later launch of the app would build.
    let reopened = try #require(RunLog(directory: temp.url).load(at: url))
    let restored = try #require(reopened.entries.first)
    #expect(restored.trashedTo == "/Users/tester/.Trash/CocoaPods")
    #expect(restored.isRestorable)
    #expect(reopened.trashedCount == 1)
    let trashed = reopened.trashedBytes
    #expect(trashed == Int64(3_221_225_472))
}

/// The other half. `simctl delete` and `avdmanager delete avd` have no Trash, so a
/// reopened record must still be able to say which rows are gone for good — otherwise
/// the interface offers a "restore" that cannot work.
@Test func aPermanentlyDeletedDeviceIsStillMarkedPermanentAfterReopening() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    let url = try log.write(record(
        startedAt: try time("2026-08-09T13:45:00Z"),
        entries: [
            RunEntry(itemID: "xcode.derivedData:/d/App", name: "App", target: "/d/App",
                     sizeBytes: 1_000, outcome: .trashed, trashedTo: "/Users/t/.Trash/App"),
            RunEntry(itemID: "ios.simulators:7F1C", name: "iPhone 17", target: "7F1C",
                     sizeBytes: 12_860_000_000, outcome: .deleted),
        ],
        notes: [Executor.Note.devicesWereRemovedPermanently]))

    let loaded = try #require(log.load(at: url))
    let permanent = try #require(loaded.permanentlyDeletedEntries.first)
    #expect(loaded.permanentlyDeletedEntries.count == 1)
    #expect(permanent.name == "iPhone 17")
    #expect(permanent.isRestorable == false)
    #expect(permanent.trashedTo == nil)
    #expect(loaded.notes.contains(Executor.Note.devicesWereRemovedPermanently))
    let permanentBytes = loaded.permanentlyDeletedBytes
    #expect(permanentBytes == Int64(12_860_000_000))
}

// MARK: - decoding a file this build did not write

/// A log written before `notes` existed — that is, by any build up to Task 17. Synthesised
/// decoding fails such a file with `keyNotFound`, `load` swallows that with `try?`, and
/// the user's whole history reads as empty, taking every `trashedTo` with it.
@Test func aLogFileMissingTheNewestFieldStillLoadsTheRun() throws {
    let temp = TempDir()
    let log = logWithRawFile(temp, named: "20260809-134500.json", json: """
    {"startedAt":"2026-08-09T13:45:00Z","finishedAt":"2026-08-09T13:45:30Z",\
    "availableBytesBefore":100,"availableBytesAfter":600,\
    "entries":[{"itemID":"other.cocoapods:/c","name":"CocoaPods cache","target":"/c",\
    "sizeBytes":2048,"outcome":"trashed","trashedTo":"/Users/tester/.Trash/CocoaPods"}]}
    """)

    let loaded = try #require(log.load(at: temp.url.appendingPathComponent("runs/20260809-134500.json")))
    let entry = try #require(loaded.entries.first)
    #expect(entry.trashedTo == "/Users/tester/.Trash/CocoaPods")
    #expect(entry.isRestorable)
    #expect(loaded.startedAt == (try time("2026-08-09T13:45:00Z")))
    #expect(loaded.freeSpaceChangeBytes == 500)
    // The one key the file predates takes its default, and nothing else moves.
    #expect(loaded.notes.isEmpty)
}

@Test func anEntryMissingItsOptionalKeysLoadsWithThemNil() throws {
    let temp = TempDir()
    let log = logWithRawFile(temp, named: "20260809-134500.json", json: """
    {"startedAt":"2026-08-09T13:45:00Z","finishedAt":"2026-08-09T13:45:30Z",\
    "availableBytesBefore":0,"availableBytesAfter":0,"notes":[],\
    "entries":[{"itemID":"a","name":"build","target":"/x","sizeBytes":7,"outcome":"deleted"}]}
    """)

    let loaded = try #require(log.load(at: temp.url.appendingPathComponent("runs/20260809-134500.json")))
    let entry = try #require(loaded.entries.first)
    #expect(entry.trashedTo == nil)
    #expect(entry.reason == nil)
    #expect(entry.isRestorable == false)
    #expect(entry.sizeBytes == Int64(7))
}

@Test func unknownKeysFromANewerVersionDoNotDiscardTheRun() throws {
    let temp = TempDir()
    let log = logWithRawFile(temp, named: "20260809-134500.json", json: """
    {"startedAt":"2026-08-09T13:45:00Z","finishedAt":"2026-08-09T13:45:30Z",\
    "availableBytesBefore":100,"availableBytesAfter":200,"notes":[],\
    "restoredAt":"2026-08-10T09:00:00Z","schemaVersion":3,\
    "entries":[{"itemID":"a","name":"build","target":"/x","sizeBytes":7,\
    "outcome":"trashed","trashedTo":"/Users/tester/.Trash/build","undoToken":"abc"}]}
    """)

    let loaded = try #require(log.load(at: temp.url.appendingPathComponent("runs/20260809-134500.json")))
    let entry = try #require(loaded.entries.first)
    #expect(entry.trashedTo == "/Users/tester/.Trash/build")
    #expect(loaded.trashedCount == 1)
}

/// One bad entry costs that entry, not the other nineteen. Dropping the whole run would
/// throw away every surviving `trashedTo` in it, which is the difference between a user
/// finding their cache in the Trash and never knowing it was moved.
@Test func oneUnreadableEntryCostsThatEntryAndNotTheWholeRun() throws {
    let temp = TempDir()
    let log = logWithRawFile(temp, named: "20260809-134500.json", json: """
    {"startedAt":"2026-08-09T13:45:00Z","finishedAt":"2026-08-09T13:45:30Z",\
    "availableBytesBefore":100,"availableBytesAfter":200,"notes":[],\
    "entries":[{"itemID":"a","name":"good","target":"/x","sizeBytes":7,\
    "outcome":"trashed","trashedTo":"/Users/tester/.Trash/x"},\
    {"itemID":"b","name":"bad","target":"/y","sizeBytes":"three gigabytes",\
    "outcome":"trashed"},\
    {"itemID":"c","name":"also good","target":"/z","sizeBytes":9,"outcome":"deleted"}]}
    """)

    let loaded = try #require(log.load(at: temp.url.appendingPathComponent("runs/20260809-134500.json")))
    #expect(loaded.entries.map(\.name) == ["good", "also good"])
    let first = try #require(loaded.entries.first)
    #expect(first.trashedTo == "/Users/tester/.Trash/x")
}

/// The same rule for an outcome this build has no case for — a log written by a newer
/// version and read by an older one.
@Test func anEntryWithAnUnknownOutcomeIsDroppedAndTheRestOfTheRunSurvives() throws {
    let temp = TempDir()
    let log = logWithRawFile(temp, named: "20260809-134500.json", json: """
    {"startedAt":"2026-08-09T13:45:00Z","finishedAt":"2026-08-09T13:45:30Z",\
    "availableBytesBefore":100,"availableBytesAfter":200,"notes":[],\
    "entries":[{"itemID":"a","name":"quarantined thing","target":"/x","sizeBytes":7,\
    "outcome":"quarantined"},\
    {"itemID":"b","name":"kept","target":"/y","sizeBytes":9,"outcome":"trashed",\
    "trashedTo":"/Users/tester/.Trash/y"}]}
    """)

    let loaded = try #require(log.load(at: temp.url.appendingPathComponent("runs/20260809-134500.json")))
    #expect(loaded.entries.map(\.name) == ["kept"])
}

/// `outcome` is required, not defaulted. There is no honest fallback for it: guessing
/// `.trashed` would tell the user a permanently deleted simulator is sitting in the Trash,
/// and guessing `.deleted` would stop them looking for a cache that really is there.
/// An entry that does not say what happened is dropped instead.
@Test func anEntryWithNoOutcomeIsDroppedRatherThanGuessed() throws {
    let temp = TempDir()
    let log = logWithRawFile(temp, named: "20260809-134500.json", json: """
    {"startedAt":"2026-08-09T13:45:00Z","finishedAt":"2026-08-09T13:45:30Z",\
    "availableBytesBefore":0,"availableBytesAfter":0,"notes":[],\
    "entries":[{"itemID":"a","name":"no outcome","target":"/x","sizeBytes":7},\
    {"itemID":"b","name":"kept","target":"/y","sizeBytes":9,"outcome":"deleted"}]}
    """)

    let loaded = try #require(log.load(at: temp.url.appendingPathComponent("runs/20260809-134500.json")))
    #expect(loaded.entries.map(\.name) == ["kept"])
    #expect(loaded.trashedCount == 0)
}

/// The general shape, so the **next** field added to `RunRecord` cannot repeat the
/// `notes` bug: a document with only the one key that identifies a run decodes to the
/// defaults instead of throwing. Any future field read with `decode` rather than
/// `decodeIfPresent` fails this the moment it is added.
///
/// Deliberately goes through `JSONDecoder` and not through `load`, which answers `nil`
/// both for a file it cannot decode and for one it decodes to nothing — the two would be
/// indistinguishable from there. Here a throw is a failure.
@Test func aRunRecordWithOnlyAStartTimeDecodesToDefaults() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try #require(#"{"startedAt":"2026-08-09T13:45:00Z"}"#.data(using: .utf8))

    let decoded = try decoder.decode(RunRecord.self, from: data)

    let started = try time("2026-08-09T13:45:00Z")
    #expect(decoded == RunRecord(startedAt: started, finishedAt: started,
                                 availableBytesBefore: 0, availableBytesAfter: 0,
                                 entries: [], notes: []))
}

/// The same guard rail one level down, for `RunEntry`.
@Test func aRunEntryWithOnlyItsIdentifyingKeysDecodesToDefaults() throws {
    let decoder = JSONDecoder()
    let data = try #require(
        #"{"itemID":"a","name":"build","target":"/x","outcome":"failed"}"#.data(using: .utf8))

    let decoded = try decoder.decode(RunEntry.self, from: data)

    #expect(decoded == RunEntry(itemID: "a", name: "build", target: "/x",
                                sizeBytes: 0, outcome: .failed))
}

/// `startedAt` is the exception: it names the run and the file, so a document without it
/// is not a run record and must not decode into one dated 1970.
@Test func aDocumentWithoutAStartTimeIsNotARunRecord() throws {
    let temp = TempDir()
    let log = logWithRawFile(temp, named: "20260809-134500.json", json: """
    {"finishedAt":"2026-08-09T13:45:30Z","availableBytesBefore":0,\
    "availableBytesAfter":0,"entries":[],"notes":[]}
    """)
    #expect(log.load(at: temp.url.appendingPathComponent("runs/20260809-134500.json")) == nil)
}

/// Half a free-space reading is no reading. Defaulting the missing side to zero would
/// make `freeSpaceChangeBytes` the whole of the other one and report a 480 GB gain from
/// a file that only lost a key.
@Test func halfAFreeSpaceReadingIsNotReportedAsAChange() throws {
    let temp = TempDir()
    let log = logWithRawFile(temp, named: "20260809-134500.json", json: """
    {"startedAt":"2026-08-09T13:45:00Z","finishedAt":"2026-08-09T13:45:30Z",\
    "availableBytesAfter":480000000000,"entries":[],"notes":[]}
    """)

    let loaded = try #require(log.load(at: temp.url.appendingPathComponent("runs/20260809-134500.json")))
    let change = loaded.freeSpaceChangeBytes
    #expect(change == Int64(0))
}

@Test func anEmptyFileLoadsAsNil() {
    let temp = TempDir()
    temp.makeFile("runs/20260809-134500.json", contents: "")
    let log = RunLog(directory: temp.url.appendingPathComponent("runs"))
    #expect(log.load(at: temp.url.appendingPathComponent("runs/20260809-134500.json")) == nil)
}

@Test func aFileThatIsNotThereLoadsAsNil() {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    #expect(log.load(at: temp.url.appendingPathComponent("20260809-134500.json")) == nil)
}

/// One damaged file costs one run. The runs either side of it still list and still load —
/// that is the whole reason a run is a file rather than a row in one document.
@Test func aCorruptFileDoesNotHideTheRunsAroundIt() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    _ = try log.write(record(startedAt: try time("2026-08-09T13:45:00Z")))
    _ = try log.write(record(startedAt: try time("2026-08-09T14:45:00Z")))
    // A file truncated by a machine that lost power mid-write.
    temp.makeFile("20260809-140000.json", contents: #"{"startedAt":"2026-08-09T1"#)

    let recent = log.recent()
    #expect(recent.count == 3)
    let readable = recent.compactMap { log.load(at: $0) }
    #expect(readable.count == 2)
    #expect(readable.map(\.startedAt) == [try time("2026-08-09T14:45:00Z"),
                                          try time("2026-08-09T13:45:00Z")])
}

// MARK: - the directory

/// Two runs starting inside the same clock second want the same name. Writing straight
/// over the first would destroy the only copy of its Trash locations.
@Test func twoRunsInTheSameSecondAreBothKept() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    let started = try time("2026-08-09T13:45:00Z")
    let first = try log.write(record(startedAt: started, entries: [
        RunEntry(itemID: "a", name: "first", target: "/x", sizeBytes: 1, outcome: .trashed,
                 trashedTo: "/Users/tester/.Trash/x"),
    ]))
    let second = try log.write(record(startedAt: started, entries: [
        RunEntry(itemID: "b", name: "second", target: "/y", sizeBytes: 2, outcome: .trashed,
                 trashedTo: "/Users/tester/.Trash/y"),
    ]))

    #expect(first != second)
    let recent = log.recent()
    #expect(recent.count == 2)
    let firstRecord = try #require(log.load(at: first))
    let secondRecord = try #require(log.load(at: second))
    #expect(firstRecord.entries.map(\.name) == ["first"])
    #expect(secondRecord.entries.map(\.name) == ["second"])
    // The later of the two still reads as the newer one in the listing.
    let newest = try #require(recent.first)
    #expect(newest == second)
}

/// The count alone cannot tell "kept the newest twenty" from "kept the oldest twenty".
@Test func pruningKeepsTheNewestRunsAndDropsTheOldest() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    let base = try time("2026-08-09T00:00:00Z")
    for index in 0..<25 {
        _ = try log.write(record(startedAt: base.addingTimeInterval(Double(index) * 60)))
    }

    let kept = log.recent(limit: 100).compactMap { log.load(at: $0)?.startedAt }
    #expect(kept.count == 20)
    // Runs 5…24 survive; 0…4 are gone.
    #expect(kept.first == base.addingTimeInterval(24 * 60))
    #expect(kept.last == base.addingTimeInterval(5 * 60))
}

@Test func recentRespectsItsLimitAndReturnsTheNewest() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    let base = try time("2026-08-09T00:00:00Z")
    for index in 0..<5 {
        _ = try log.write(record(startedAt: base.addingTimeInterval(Double(index) * 60)))
    }

    let recent = log.recent(limit: 2)
    #expect(recent.count == 2)
    let newestURL = try #require(recent.first)
    let nextURL = try #require(recent.last)
    #expect(log.load(at: newestURL)?.startedAt == base.addingTimeInterval(240))
    #expect(log.load(at: nextURL)?.startedAt == base.addingTimeInterval(180))
}

/// `Array.prefix` traps on a negative length. A crash in place of an empty list would
/// take the app down over its own history view.
@Test func recentWithANonPositiveLimitReturnsNothingInsteadOfTrapping() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    _ = try log.write(record(startedAt: try time("2026-08-09T13:45:00Z")))
    #expect(log.recent(limit: 0).isEmpty)
    #expect(log.recent(limit: -1).isEmpty)
}

@Test func recentIsEmptyBeforeAnythingHasEverBeenWritten() {
    let temp = TempDir()
    let log = RunLog(directory: temp.url.appendingPathComponent("runs"))
    #expect(log.recent().isEmpty)
}

@Test func writeCreatesTheDirectoryWhenItDoesNotExistYet() throws {
    let temp = TempDir()
    let directory = temp.url.appendingPathComponent("DevCleaner/runs", isDirectory: true)
    let log = RunLog(directory: directory)
    let url = try log.write(record(startedAt: try time("2026-08-09T13:45:00Z")))
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(log.recent().count == 1)
}

/// Only this log's own files are listed. A `README` or an editor's backup dropped into
/// the directory must not appear as a run.
@Test func filesThatAreNotRunsAreIgnored() throws {
    let temp = TempDir()
    let log = RunLog(directory: temp.url)
    _ = try log.write(record(startedAt: try time("2026-08-09T13:45:00Z")))
    temp.makeFile("notes.txt", contents: "hello")
    temp.makeFile(".DS_Store", contents: "x")
    #expect(log.recent().count == 1)
}

@Test func stampIsFixedWidthUTCAndSortsByTime() throws {
    #expect(RunLog.stamp(try time("2026-08-09T13:45:00Z")) == "20260809-134500")
    // Single-digit month, day, hour, minute and second are all padded, which is what
    // makes a plain string sort a time sort.
    #expect(RunLog.stamp(try time("2026-01-02T03:04:05Z")) == "20260102-030405")
    #expect(RunLog.stamp(try time("2026-01-02T03:04:05Z"))
            < RunLog.stamp(try time("2026-01-02T03:04:06Z")))
}

@Test func retentionAndDefaultDirectoryMatchTheSpec() {
    #expect(RunLog.retainedRuns == 20)
    // No file is written here; the paths are only compared.
    #expect(RunLog.defaultDirectory().lastPathComponent == "runs")
    #expect(RunLog.defaultDirectory().deletingLastPathComponent()
            == SettingsStore.defaultDirectory())
}
