import Testing
import Foundation
@testable import CleanerCore

private let now = Date(timeIntervalSince1970: 1_786_000_000)

private func context(
    temp: TempDir, protection: ProtectionSet = .empty, sizes: [String: Int64] = [:],
    settings: Settings? = nil, sizeMeasurer: (any SizeMeasuring)? = nil
) -> ScanContext {
    ScanContext(
        settings: settings ?? .makeDefault(home: temp.path),
        protection: protection, projects: [], devices: .empty,
        home: temp.path, androidSDKPath: temp.path + "/Library/Android/sdk",
        sizeMeasurer: sizeMeasurer ?? FixedSizeMeasurer(sizes),
        runner: FakeProcessRunner(responses: [:]),
        fileManager: .default, now: now)
}

/// Builds a `ProtectionSet` holding one protected project. The memberwise
/// initialiser has no defaults and gained two fields in Task 8, so spelling it out
/// once keeps the tests readable.
private func protecting(_ projectPath: String, _ reason: ProtectionReason) -> ProtectionSet {
    ProtectionSet(
        projects: [projectPath: reason],
        keptSimulatorUDID: nil, keptAVDName: nil,
        protectedSimulatorUDIDs: [:], protectedAVDNames: [:],
        flutterVersions: [:], gradleDistributions: [:], runtimeIdentifiers: [:])
}

private func writeDerivedData(_ temp: TempDir, name: String, workspace: String?) -> String {
    let path = temp.makeDirectory("Library/Developer/Xcode/DerivedData/\(name)")
    if let workspace {
        temp.makeFile("Library/Developer/Xcode/DerivedData/\(name)/info.plist", contents: """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>WorkspacePath</key><string>\(workspace)</string>
        </dict></plist>
        """)
    }
    return path
}

@Test func derivedDataEntryForUnprotectedProjectIsDeletable() async throws {
    let temp = TempDir()
    // The workspace is created on disk: this entry is offered because its project
    // is unprotected, not because the project folder has gone.
    let workspace = temp.makeDirectory("dev/stale/Stale.xcodeproj")
    let path = writeDerivedData(temp, name: "Stale-abc123", workspace: workspace)
    let items = await DerivedDataScanner().scan(context(temp: temp, sizes: [path: 5_000_000_000]))

    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.scannerID == "xcode.derivedData")
    #expect(item.group == .xcodeAndIOS)
    #expect(item.name == "Stale-abc123")
    #expect(item.sizeBytes == 5_000_000_000)
    #expect(item.isDeletable)
    #expect(item.detail == nil)
    #expect(item.method == .removePath(path))
}

@Test func derivedDataEntryForProtectedProjectIsKept() async throws {
    let temp = TempDir()
    let projectRoot = temp.makeDirectory("dev/sample-project")
    let workspace = temp.makeDirectory("dev/sample-project/ios/Runner.xcworkspace")
    _ = writeDerivedData(temp, name: "SampleProject-xyz", workspace: workspace)
    let protection = protecting(projectRoot, .recentActivity(days: 14))

    let items = await DerivedDataScanner().scan(context(temp: temp, protection: protection))
    let item = try #require(items.first)
    #expect(item.protection == .recentActivity(days: 14))
    #expect(!item.isDeletable)
    #expect(item.detail == "kept for sample-project")
}

@Test func derivedDataOrphanWithoutPlistIsDeletable() async throws {
    let temp = TempDir()
    _ = writeDerivedData(temp, name: "Ghost-000", workspace: nil)
    let items = await DerivedDataScanner().scan(context(temp: temp))
    let item = try #require(items.first)
    #expect(item.isDeletable)
    #expect(item.detail == "no matching project")
}

@Test func derivedDataModuleCacheIsNotTreatedAsAProject() async throws {
    let temp = TempDir()
    temp.makeDirectory("Library/Developer/Xcode/DerivedData/ModuleCache.noindex")
    let items = await DerivedDataScanner().scan(context(temp: temp))
    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.isDeletable)
}

@Test func missingDerivedDataDirectoryYieldsNoItems() async {
    let temp = TempDir()
    #expect(await DerivedDataScanner().scan(context(temp: temp)).isEmpty)
}

@Test func archivesOlderThanThresholdAreDeletableAtElevatedRisk() async throws {
    let temp = TempDir()
    temp.makeDirectory("Library/Developer/Xcode/Archives/2026-01-04/Old.xcarchive")
    let oldPath = temp.path + "/Library/Developer/Xcode/Archives/2026-01-04/Old.xcarchive"
    try! FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-86_400 * 200)], ofItemAtPath: oldPath)

    let items = await ArchivesScanner().scan(context(temp: temp, sizes: [oldPath: 900_000_000]))
    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.isDeletable)
    #expect(item.risk == .elevated)
    #expect(item.sizeBytes == 900_000_000)
    #expect(item.method == .removePath(oldPath))
}

/// Nothing in the brief's fixtures sits on the cutoff, so `<` and `<=` behave
/// alike. An archive whose timestamp equals the cutoff is exactly `archiveAgeDays`
/// old, not older, and is kept.
@Test func anArchiveExactlyAtTheCutoffIsKept() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Developer/Xcode/Archives/2026-07-10/Boundary.xcarchive")
    let path = temp.path + "/Library/Developer/Xcode/Archives/2026-07-10/Boundary.xcarchive"
    let settings = Settings.makeDefault(home: temp.path)
    let cutoff = now.addingTimeInterval(-Double(settings.archiveAgeDays) * 86_400)
    try! FileManager.default.setAttributes(
        [.modificationDate: cutoff], ofItemAtPath: path)

    #expect(await ArchivesScanner().scan(context(temp: temp, settings: settings)).isEmpty)
}

/// The other side of the same boundary: one second older and it is offered.
@Test func anArchiveOneSecondPastTheCutoffIsOffered() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Developer/Xcode/Archives/2026-07-10/Boundary.xcarchive")
    let path = temp.path + "/Library/Developer/Xcode/Archives/2026-07-10/Boundary.xcarchive"
    let settings = Settings.makeDefault(home: temp.path)
    let cutoff = now.addingTimeInterval(-Double(settings.archiveAgeDays) * 86_400)
    try! FileManager.default.setAttributes(
        [.modificationDate: cutoff.addingTimeInterval(-1)], ofItemAtPath: path)

    let items = await ArchivesScanner().scan(context(temp: temp, settings: settings))
    #expect(items.count == 1)
}

@Test func recentArchivesAreNotOffered() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Developer/Xcode/Archives/2026-08-01/Fresh.xcarchive")
    let path = temp.path + "/Library/Developer/Xcode/Archives/2026-08-01/Fresh.xcarchive"
    try! FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-86_400 * 3)], ofItemAtPath: path)

    #expect(await ArchivesScanner().scan(context(temp: temp)).isEmpty)
}

@Test func archiveAgeThresholdComesFromSettings() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Developer/Xcode/Archives/2026-07-01/Mid.xcarchive")
    let path = temp.path + "/Library/Developer/Xcode/Archives/2026-07-01/Mid.xcarchive"
    try! FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-86_400 * 10)], ofItemAtPath: path)

    var settings = Settings.makeDefault(home: temp.path)
    settings.archiveAgeDays = 7
    let items = await ArchivesScanner().scan(context(temp: temp, settings: settings))
    #expect(items.count == 1)
}

/// Added after mutation testing: dropping the `.xcarchive` suffix filter left every
/// brief test passing, because each fixture holds nothing else. Anything else a date
/// folder happens to hold is not a build and must not be offered.
@Test func archivesScannerIgnoresEntriesThatAreNotArchives() async throws {
    let temp = TempDir()
    temp.makeDirectory("Library/Developer/Xcode/Archives/2026-01-04/Old.xcarchive")
    let archive = temp.path + "/Library/Developer/Xcode/Archives/2026-01-04/Old.xcarchive"
    try! FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-86_400 * 200)], ofItemAtPath: archive)
    temp.makeFile(
        "Library/Developer/Xcode/Archives/2026-01-04/release-notes.txt",
        modified: now.addingTimeInterval(-86_400 * 200))

    let items = await ArchivesScanner().scan(context(temp: temp))
    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == "Old")
    #expect(item.method == .removePath(archive))
}

/// Added after mutation testing: a bare `hasPrefix` on the protected project path
/// left every brief test passing, yet it matches `app-legacy` against `app` and
/// keeps derived data that belongs to a different project.
@Test func derivedDataIsNotMatchedToASiblingProjectSharingAPathPrefix() async throws {
    let temp = TempDir()
    let pinned = temp.makeDirectory("dev/app")
    // Created on disk, so only the prefix rule decides the outcome.
    let legacyWorkspace = temp.makeDirectory("dev/app-legacy/App.xcodeproj")
    _ = writeDerivedData(temp, name: "Legacy-abc", workspace: legacyWorkspace)

    let items = await DerivedDataScanner().scan(
        context(temp: temp, protection: protecting(pinned, .pinnedProject)))
    let item = try #require(items.first)
    #expect(item.protection == nil)
    #expect(item.isDeletable)
}

/// Xcode names a DerivedData folder from a hash of the workspace path, so once
/// that workspace is deleted nothing will ever build into the folder again. Four
/// of five real entries on the development machine pointed at git worktrees, two
/// of which no longer existed — 6.27 GB held only because the recorded string
/// still began with a live project root.
@Test func derivedDataForAWorkspaceThatNoLongerExistsIsOffered() async throws {
    let temp = TempDir()
    let projectRoot = temp.makeDirectory("dev/app")
    let liveWorkspace = temp.makeDirectory("dev/app/worktrees/live/App.xcodeproj")
    let goneWorkspace = projectRoot + "/worktrees/gone/App.xcodeproj"   // never created

    _ = writeDerivedData(temp, name: "Live-aaa", workspace: liveWorkspace)
    _ = writeDerivedData(temp, name: "Gone-bbb", workspace: goneWorkspace)

    let items = await DerivedDataScanner().scan(
        context(temp: temp, protection: protecting(projectRoot, .recentActivity(days: 14))))

    let live = try #require(items.first { $0.name == "Live-aaa" })
    #expect(!live.isDeletable)
    #expect(live.protection == .recentActivity(days: 14))

    let gone = try #require(items.first { $0.name == "Gone-bbb" })
    #expect(gone.isDeletable)
    #expect(gone.protection == nil)
    #expect(gone.detail == "its project folder is gone")
}

/// `sizes(of:)` batches and holds four `du` processes open at most, so calling it
/// once per path silently defeats that cap. No item a scanner returns shows it.
@Test func derivedDataMeasuresEveryEntryInOneBatchedCall() async throws {
    let temp = TempDir()
    for name in ["One-a", "Two-b", "Three-c"] {
        _ = writeDerivedData(temp, name: name, workspace: nil)
    }
    let measurer = CallCountingSizeMeasurer()

    let items = await DerivedDataScanner().scan(context(temp: temp, sizeMeasurer: measurer))
    #expect(items.count == 3)

    let callCount = await measurer.callCount
    #expect(callCount == 1)
    let batches = await measurer.batches
    let batch = try #require(batches.first)
    #expect(batch.count == 3)
}

/// Added after mutation testing: the identifiers are persisted in
/// `Settings.alwaysSkipScannerIDs`, so renaming one silently un-skips it for an
/// existing user. Only `xcode.derivedData` was pinned by the brief.
@Test func scannerIdentitiesAndGroupsAreStable() {
    #expect(DerivedDataScanner().id == "xcode.derivedData")
    #expect(ArchivesScanner().id == "xcode.archives")
    #expect(DeviceSupportScanner().id == "xcode.deviceSupport")
    #expect(DerivedDataScanner().group == .xcodeAndIOS)
    #expect(ArchivesScanner().group == .xcodeAndIOS)
    #expect(DeviceSupportScanner().group == .xcodeAndIOS)
}

// MARK: - device support: the folder in use is kept

/// Writes one device support folder with a modification date, and answers its path.
///
/// The date is the whole of the keeping rule, so it is never defaulted: a fixture that
/// left it to whatever the filesystem stamped would be testing the order `mkdir` happened
/// to run in.
private func writeDeviceSupport(
    _ temp: TempDir, platform: String = "iOS", _ name: String, modified: Date?
) -> String {
    let relative = "Library/Developer/Xcode/\(platform) DeviceSupport/\(name)"
    let path = temp.makeDirectory(relative)
    if let modified {
        try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    }
    return path
}

private let september14 = Date(timeIntervalSince1970: 1_757_808_000)
private let september2 = Date(timeIntervalSince1970: 1_756_771_200)
private let august30 = Date(timeIntervalSince1970: 1_756_512_000)

/// The four folders a real dev machine has, and the two the tool may offer.
///
/// 27 GB sat here offered and ticked under the sentence "rebuilt when you next connect a
/// device". "Rebuilt" was Xcode copying about 7 GB of symbols back off the phone over a
/// cable — several minutes of "Preparing device for development" before the next build —
/// so the folder the phone is actually running had to stop being offered. The two
/// abandoned betas are the dead weight, and they are what is left.
@Test func onlyTheOlderDeviceSupportBuildsOfOneDeviceAreOffered() async throws {
    let temp = TempDir()
    let release = writeDeviceSupport(temp, "iPhone17,2 27.0 (24A435)", modified: september14)
    let olderBeta = writeDeviceSupport(temp, "iPhone17,2 27.0 (24A5424a)", modified: august30)
    let newerBeta = writeDeviceSupport(temp, "iPhone17,2 27.0 (24A5430a)", modified: september2)
    let iPad = writeDeviceSupport(temp, "iPad15,7 26.6 (23G71)", modified: august30)

    let items = await DeviceSupportScanner().scan(context(temp: temp, sizes: [
        release: 7_000_000_000, olderBeta: 6_800_000_000,
        newerBeta: 6_900_000_000, iPad: 6_300_000_000,
    ]))

    #expect(items.filter(\.isDeletable).map(\.method)
            == [.removePath(olderBeta), .removePath(newerBeta)])
    // The iPad's only folder is kept as well: a family of one is always the newest of its
    // family, which is what stops this rule from emptying a device that was connected once.
    #expect(items.filter { !$0.isDeletable }.map(\.method)
            == [.removePath(iPad), .removePath(release)])
    #expect(items.filter { !$0.isDeletable }.allSatisfy { $0.protection == .newestDeviceSupport })
}

/// The totals follow, which is the number the user reads. 27.0 GB of device support is
/// really 13.7 GB of it, and the rest is the price of the next build.
@Test func theKeptDeviceSupportFoldersAreNotCountedAsReclaimable() async {
    let temp = TempDir()
    let release = writeDeviceSupport(temp, "iPhone17,2 27.0 (24A435)", modified: september14)
    let beta = writeDeviceSupport(temp, "iPhone17,2 27.0 (24A5424a)", modified: august30)
    let iPad = writeDeviceSupport(temp, "iPad15,7 26.6 (23G71)", modified: august30)

    let items = await DeviceSupportScanner().scan(context(temp: temp, sizes: [
        release: 7_000_000_000, beta: 6_800_000_000, iPad: 6_300_000_000,
    ]))
    let result = ScanResult(items: items, generatedAt: now, availableBytes: 0,
                            skippedScannerIDs: [])

    #expect(result.reclaimableBytes == 6_800_000_000)
    #expect(result.items.count == 3)
}

/// Each row says which device it is for and what letting it go costs — the wording is what
/// makes the offer honest, so it is pinned rather than left to drift.
@Test func deviceSupportRowsSayWhichDeviceTheyBelongToAndWhichOneXcodeUses() async throws {
    let temp = TempDir()
    let release = writeDeviceSupport(temp, "iPhone17,2 27.0 (24A435)", modified: september14)
    let beta = writeDeviceSupport(temp, "iPhone17,2 27.0 (24A5424a)", modified: august30)

    let items = await DeviceSupportScanner().scan(context(
        temp: temp, sizes: [release: 7_000_000_000, beta: 6_800_000_000]))

    let kept = try #require(items.first { $0.method == .removePath(release) })
    #expect(kept.detail == "the one Xcode uses for iPhone17,2 now")
    let offered = try #require(items.first { $0.method == .removePath(beta) })
    #expect(offered.detail
            == "an older iOS build for iPhone17,2 — Xcode uses the newer one")
    // The sentence that used to be here promised a rebuild that does not happen, so no row
    // may carry it any more.
    #expect(items.allSatisfy { $0.detail != "rebuilt when you next connect a device" })
    // Nothing on this Mac remakes it: the symbols come off the device, and for an
    // abandoned beta that device may never run that build again.
    #expect(items.allSatisfy { $0.risk == .elevated })
}

/// A watch and a phone are never in one family, so each keeps its own newest folder.
///
/// This is also the test that used to assert both were offered. Both are now kept, because
/// each is the only folder for its device — which is the rule working, not an omission.
@Test func watchDeviceSupportIsAFamilyOfItsOwnAndKeepsItsOwnNewest() async {
    let temp = TempDir()
    let ios = writeDeviceSupport(temp, "iPhone17,2 18.2", modified: september14)
    let watch = writeDeviceSupport(temp, platform: "watchOS", "Watch7,1 11.2",
                                   modified: august30)

    let items = await DeviceSupportScanner().scan(context(
        temp: temp, sizes: [ios: 2_000_000_000, watch: 900_000_000]))

    #expect(items.map(\.name) == ["iOS iPhone17,2 18.2", "watchOS Watch7,1 11.2"])
    #expect(items.map(\.method) == [.removePath(ios), .removePath(watch)])
    #expect(items.allSatisfy { $0.protection == .newestDeviceSupport })
}

/// A folder named the way older Xcode named them — the build alone, no device model.
///
/// Grouped by its first word, `16.4` and `17.1` would be two families and both would be
/// kept, which is the whole bug inverted: nothing would ever be offered. They fall into one
/// family per platform instead, so the newest of them survives and the rest are offered.
@Test func deviceSupportFoldersWithNoDeviceModelShareOneFamilyPerPlatform() async throws {
    let temp = TempDir()
    let older = writeDeviceSupport(temp, "16.4 (20F66)", modified: august30)
    let newer = writeDeviceSupport(temp, "17.1 (21B74)", modified: september14)

    let items = await DeviceSupportScanner().scan(context(
        temp: temp, sizes: [older: 5_000_000_000, newer: 6_000_000_000]))

    #expect(items.filter(\.isDeletable).map(\.method) == [.removePath(older)])
    let offered = try #require(items.first { $0.method == .removePath(older) })
    // No model to name, so the sentence says "this device" rather than inventing one.
    #expect(offered.detail == "an older iOS build for this device — Xcode uses the newer one")
    let kept = try #require(items.first { $0.method == .removePath(newer) })
    #expect(kept.detail == "the one Xcode uses for this device now")
    #expect(DeviceSupportScanner.model(inFolderNamed: "16.4 (20F66)") == nil)
    #expect(DeviceSupportScanner.model(inFolderNamed: "iPhone17,2 27.0 (24A435)") == "iPhone17,2")
}

/// Two folders modified at the same instant. The winner is fixed rather than whichever the
/// directory listing happened to put first: a keeping rule that moved between scans would
/// offer the live folder every other time.
@Test func deviceSupportTiesOnTheDateAreBrokenByTheNameThatSortsLast() async {
    let temp = TempDir()
    let first = writeDeviceSupport(temp, "iPhone17,2 27.0 (24A100)", modified: september14)
    let last = writeDeviceSupport(temp, "iPhone17,2 27.0 (24A999)", modified: september14)

    let items = await DeviceSupportScanner().scan(context(
        temp: temp, sizes: [first: 7_000_000_000, last: 7_000_000_000]))

    #expect(items.filter(\.isDeletable).map(\.method) == [.removePath(first)])
    #expect(items.filter { !$0.isDeletable }.map(\.method) == [.removePath(last)])
}

/// An unknown date never beats a known one. Keeping the undated folder would leave the live
/// one offered and ticked, which is the outcome this whole rule exists to prevent — and
/// "no date" is not evidence of anything, unlike a date.
@Test func aDeviceSupportFolderWithNoDateNeverWinsOverOneThatHasOne() async {
    let temp = TempDir()
    // `newest(of:)` is asked directly rather than through a fixture, because a real
    // directory entry always has a modification date: `nil` is what
    // `ScanHelpers.children` answers when it cannot read the attributes at all, which no
    // temporary directory can be made to do. The rule is still the one the scan depends on.
    let dated = writeDeviceSupport(temp, "iPhone17,2 27.0 (24A435)", modified: september14)

    let undated = DeviceSupportScanner.Candidate(
        child: ScanHelpers.Child(name: "iPhone17,2 27.0 (24A9999)",
                                 path: "/tmp/undated", isDirectory: true, modified: nil),
        platform: "iOS", model: "iPhone17,2")
    let known = DeviceSupportScanner.Candidate(
        child: ScanHelpers.Child(name: "iPhone17,2 27.0 (24A435)",
                                 path: dated, isDirectory: true, modified: august30),
        platform: "iOS", model: "iPhone17,2")

    #expect(DeviceSupportScanner.newest(of: [undated, known])?.child.path == dated)
    #expect(DeviceSupportScanner.newest(of: [known, undated])?.child.path == dated)
    // With nothing dated at all, the name that sorts last wins — arbitrary, but fixed.
    let otherUndated = DeviceSupportScanner.Candidate(
        child: ScanHelpers.Child(name: "iPhone17,2 27.0 (24A0001)",
                                 path: "/tmp/other", isDirectory: true, modified: nil),
        platform: "iOS", model: "iPhone17,2")
    #expect(DeviceSupportScanner.newest(of: [undated, otherUndated])?.child.path
            == "/tmp/undated")
}
