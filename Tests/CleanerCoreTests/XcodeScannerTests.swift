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

@Test func deviceSupportEntriesAreAlwaysDeletable() async throws {
    let temp = TempDir()
    let path = temp.makeDirectory("Library/Developer/Xcode/iOS DeviceSupport/18.2 (22C150)")
    let items = await DeviceSupportScanner().scan(context(temp: temp, sizes: [path: 3_000_000_000]))
    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.isDeletable)
    #expect(item.sizeBytes == 3_000_000_000)
    #expect(item.method == .removePath(path))
}

@Test func watchDeviceSupportIsOfferedSeparatelyFromIOSSupport() async throws {
    let temp = TempDir()
    let ios = temp.makeDirectory("Library/Developer/Xcode/iOS DeviceSupport/18.2")
    let watch = temp.makeDirectory("Library/Developer/Xcode/watchOS DeviceSupport/11.2")

    let items = await DeviceSupportScanner().scan(context(
        temp: temp, sizes: [ios: 2_000_000_000, watch: 900_000_000]))

    #expect(items.map(\.name) == ["iOS 18.2", "watchOS 11.2"])
    #expect(items.map(\.method) == [.removePath(ios), .removePath(watch)])
}
