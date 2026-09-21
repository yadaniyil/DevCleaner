import Testing
import Foundation
@testable import CleanerCore

private let now = Date(timeIntervalSince1970: 1_786_000_000)

/// Over `LargeFileLicence.minimumBytes`, so a fixture only has to say "large".
private let large: Int64 = 1_700_000_000

/// The one command this scanner may run, spelled the way `commandKey` spells it.
private func mdfindKey(_ home: String) -> String {
    commandKey(LargeFilesScanner.mdfindPath,
               ["-onlyin", home, LargeFilesScanner.spotlightQuery])
}

/// A context whose Spotlight answers with exactly these lines.
///
/// The paths are joined with newlines and handed back as `mdfind`'s standard output, so a
/// test can say what the index claims independently of what is on disk — which is the whole
/// point of this scanner's rules.
private func context(temp: TempDir, answering paths: [String]) -> ScanContext {
    context(temp: temp, result: ProcessResult(
        exitCode: 0, stdout: paths.joined(separator: "\n"), stderr: ""))
}

private func context(temp: TempDir, result: ProcessResult) -> ScanContext {
    context(temp: temp, runner: FakeProcessRunner(responses: [mdfindKey(temp.path): result]))
}

private func context(temp: TempDir, runner: any ProcessRunner) -> ScanContext {
    ScanContext(
        settings: .makeDefault(home: temp.path), protection: .empty, projects: [],
        devices: .empty, home: temp.path, androidSDKPath: temp.path + "/sdk",
        // Deliberately a measurer that answers nothing. This scanner never asks it: the
        // size comes from the same `lstat` that decided the thing is a regular file, and
        // `du` on 56 individual files would be 56 processes for numbers `stat` already has.
        sizeMeasurer: PartialSizeMeasurer([:]),
        runner: runner, fileManager: .default, now: now)
}

/// The path the scanner will name, which is the canonical one: a `TempDir` lives under
/// `/var/folders`, and `/var` is a symlink to `/private/var`.
private func canonical(_ path: String) -> String {
    PathGuard.canonicaliseKeepingLeaf(path) ?? path
}

// MARK: - the folders macOS guards

/// The first real scan offered thirty files under `~/dev` and none of the twenty-three in
/// `~/Documents`: Spotlight answers a process without the grant as if the folder were empty.
/// Listing the folder is what makes macOS ask, so these are the two the page asks for —
/// and `Downloads`, the third guarded folder, stays `big.downloads`' to ask about.
@Test func thePageAsksForDocumentsAndDesktopAndLeavesDownloadsToItsOwnScanner() {
    #expect(LargeFilesScanner.foldersBehindAPermissionPrompt == ["Documents", "Desktop"])
    #expect(!LargeFilesScanner.foldersBehindAPermissionPrompt.contains("Downloads"))
}

/// Asking is never what breaks a scan: a home with neither folder, or one the user refused,
/// is an ordinary scan that finds whatever Spotlight still names.
@Test func aHomeWithoutTheGuardedFoldersStillScans() async {
    let temp = TempDir()
    let film = temp.makeFile("films/lesson 26.mp4", bytes: large)

    let items = await LargeFilesScanner().scan(context(temp: temp, answering: [film]))

    #expect(items.map(\.name) == ["lesson 26.mp4"])
}

// MARK: - the row

/// The four things the row is made of, over a real file, with Spotlight naming it.
@Test func aLargeFileIsOfferedByNameWithItsFolderItsSizeAndWhenItChanged() async throws {
    let temp = TempDir()
    let changed = Date(timeIntervalSince1970: 1_700_000_000)
    let film = temp.makeFile("Documents/videos/lesson 26.mp4", bytes: 582_000_000,
                             modified: changed)

    let items = await LargeFilesScanner().scan(context(temp: temp, answering: [film]))

    let item = try #require(items.first)
    #expect(items.count == 1)
    #expect(item.name == "lesson 26.mp4")
    // The folder, abbreviated, because that is what tells two rows apart: sixteen sibling
    // folders on the user's Mac each hold a `scan.pdf`.
    #expect(item.detail == "~/Documents/videos")
    // Read off the disk, not out of the index.
    #expect(item.sizeBytes == 582_000_000)
    #expect(item.lastUsed == changed)
    // The canonical path, which is the only one it is safe to act on.
    #expect(item.method == .removePath(canonical(film)))
    #expect(item.id == "big.largeFiles|" + canonical(film))
}

/// The three properties every big thing carries, and the one this group exists for.
@Test func everyLargeFileRowIsIrreplaceableUntickedAndInTheBigThingsGroup() async throws {
    let temp = TempDir()
    let film = temp.makeFile("Documents/films/holiday.mov", bytes: large)

    let items = await LargeFilesScanner().scan(context(temp: temp, answering: [film]))

    let item = try #require(items.first)
    #expect(item.group == .bigThings)
    #expect(item.risk == .irreplaceable)
    #expect(item.startsUnticked)
    // Deletable and never ticked: two different facts, both needed. The checklist page is
    // what ticks these, and no default route may.
    #expect(item.isDeletable)
    #expect(!item.selectedByDefault)
    // No `untickedReason`: the reason is a decision about the app, not a `ProtectionReason`
    // about the file. Same as the rest of `GroupID.bigThings`.
    #expect(item.untickedReason == nil)
    #expect(!item.sizeMayBeShared)
}

@Test func theScannerCarriesItsIdentityAsStaticsAndDealsAChecklist() {
    #expect(LargeFilesScanner.scannerID == "big.largeFiles")
    #expect(LargeFilesScanner().id == LargeFilesScanner.scannerID)
    #expect(LargeFilesScanner().group == .bigThings)
    #expect(LargeFilesScanner().title == "Large files")
    #expect(LargeFilesScanner().deckDealing == .checklist)
}

// MARK: - Spotlight, and only Spotlight

/// The floor, and the one command the scanner is allowed to run.
///
/// `RecordingProcessRunner`, so this also says what the scanner does **not** do: no `du`,
/// no `find`, no second query. Everything goes through the injected runner, which is what
/// makes the whole of this file possible without touching the real Spotlight.
@Test func theOnlyCommandIsMdfindWithTheTwoHundredMegabyteFloor() async {
    let temp = TempDir()
    let runner = RecordingProcessRunner()

    _ = await LargeFilesScanner().scan(context(temp: temp, runner: runner))

    #expect(LargeFileLicence.minimumBytes == 200_000_000)
    #expect(LargeFilesScanner.spotlightQuery == "kMDItemFSSize>=200000000")
    #expect(runner.recorded == [mdfindKey(temp.path)])
}

/// **Every way Spotlight can fail to answer is the same answer: no rows.**
///
/// The fixture is the discriminating half. A 1.7 GB file sits in the home folder and
/// `mdfind` does not name it, so a scanner that fell back to walking — which on a real home
/// folder would be minutes of work — would find it and offer it. None of these cases may.
@Test func spotlightFailingEmptyOrMissingIsNoRowsAndNeverAWalkOfTheHomeFolder() async {
    let temp = TempDir()
    temp.makeFile("Documents/films/unindexed.mov", bytes: large)

    // Spotlight switched off for the volume: mdfind exits non-zero.
    let refused = await LargeFilesScanner().scan(context(temp: temp, result: ProcessResult(
        exitCode: 1, stdout: "", stderr: "mdfind: Spotlight is disabled")))
    #expect(refused.isEmpty)

    // Indexed, and nothing over the floor.
    let empty = await LargeFilesScanner().scan(context(temp: temp, result: ProcessResult(
        exitCode: 0, stdout: "", stderr: "")))
    #expect(empty.isEmpty)

    // No stub at all, which is `FakeProcessRunner`'s "there is no such command": the shape
    // of `mdfind` missing or refusing to start, where `run` throws rather than exits.
    let unavailable = await LargeFilesScanner()
        .scan(context(temp: temp, runner: FakeProcessRunner(responses: [:])))
    #expect(unavailable.isEmpty)
}

/// Spotlight is an index, not the truth, and every one of these paths is one it can hand
/// back: it lists what was there when it last looked.
@Test func everyPathSpotlightNamesIsRecheckedOnDisk() async {
    let temp = TempDir()
    let gone = temp.path + "/Documents/deleted-since-the-index.mov"
    let folder = temp.makeDirectory("Documents/a folder.mov")
    let big = temp.makeFile("Documents/target.mov", bytes: large)
    let link = temp.makeSymlink("Documents/link.mov", to: big)
    let shrunk = temp.makeFile("Documents/truncated.mov", bytes: 12)

    let items = await LargeFilesScanner()
        .scan(context(temp: temp, answering: [gone, folder, link, shrunk, big]))

    // Only the regular file over the floor. A directory would be a whole tree removed for
    // a row that said it was a file; a symlink's size is its target's while trashing it
    // frees nothing; a file that has shrunk since the index is not the thing the row
    // describes.
    #expect(items.map(\.method) == [.removePath(canonical(big))])
}

/// `mdfind` output is data from outside the program, and none of it is trusted.
@Test func untrustedSpotlightOutputIsDroppedRatherThanFollowed() async {
    let temp = TempDir()
    let outside = TempDir()
    let elsewhere = outside.makeFile("someone-elses.mov", bytes: large)
    temp.makeFile("Library/Application Support/Big/store.bin", bytes: large)
    let wanted = temp.makeFile("Documents/keep.mov", bytes: large)

    let items = await LargeFilesScanner().scan(context(temp: temp, answering: [
        // Relative: resolves against whatever directory the process runs in, so its
        // verdict would depend on that.
        "Documents/keep.mov",
        "",
        "   ",
        // A stray carriage return, which is what a line arrives as when something between
        // the index and here has rewritten it. It names no file on disk.
        wanted + "\r",
        // Outside the home folder altogether.
        elsewhere,
        // A `..` that climbs out of the rules: this resolves into `~/Library`.
        temp.path + "/Documents/../Library/Application Support/Big/store.bin",
        // The home folder itself, and its parent.
        temp.path,
        (temp.path as NSString).deletingLastPathComponent,
        wanted,
    ]))

    #expect(items.map(\.method) == [.removePath(canonical(wanted))])
}

/// A file named through a symlinked parent is offered **under its real path**, once.
///
/// `mdfind` answers with resolved paths, so this is about what the rule does rather than
/// about what Spotlight says — and it is the property the whole licence rests on: the path
/// that was checked is the path that may be removed, and a second spelling of one file does
/// not take a second row.
@Test func aFileNamedThroughASymlinkedParentIsOfferedOnceUnderItsRealPath() async {
    let temp = TempDir()
    let film = temp.makeFile("Documents/films/holiday.mov", bytes: large)
    temp.makeSymlink("shortcut", to: temp.path + "/Documents/films")

    let items = await LargeFilesScanner().scan(context(
        temp: temp, answering: [temp.path + "/shortcut/holiday.mov", film]))

    #expect(items.map(\.method) == [.removePath(canonical(film))])
}

// MARK: - what is never offered

@Test func nothingUnderLibraryOrDownloadsIsEverOffered() async {
    let temp = TempDir()
    let library = temp.makeFile("Library/Caches/Big/blob.bin", bytes: large)
    // The exclusion is a **whole-component** match, not a prefix: a folder of the user's own
    // whose name merely begins with "Library" is theirs, and a rule written as `hasPrefix`
    // would silently stop offering anything in it. The comparison is case-insensitive
    // because a home holding a lower-cased `library` names the same directory on a
    // case-insensitive volume — which is why that is not what this fixture is.
    let shouted = temp.makeFile("LIBRARY-not-really/blob.bin", bytes: large)
    let download = temp.makeFile("Downloads/Xcode_26.1_beta.xip", bytes: large)
    let nested = temp.makeFile("Downloads/conference/day-one.mov", bytes: large)
    let appSupport = temp.makeFile(
        "Library/Application Support/DevCleaner/cache.json", bytes: large)

    let items = await LargeFilesScanner().scan(context(
        temp: temp, answering: [library, download, nested, appSupport, shouted]))

    // `~/Library` is the machine's, not the user's — and it holds this app's own scan
    // cache, so a scan that offered it would be offering the file the next scan is read
    // from. `~/Downloads` belongs to `big.downloads`, grandchildren included: one file
    // offered by two scanners is two cards for one decision.
    #expect(items.map(\.name) == ["blob.bin"])
    #expect(items.map(\.method) == [.removePath(canonical(shouted))])
    #expect(LargeFileLicence.excludedTopLevelFolders == ["Library", "Downloads"])
}

@Test func nothingWithAHiddenPathComponentIsEverOffered() async {
    let temp = TempDir()
    let trashed = temp.makeFile(".Trash/already-thrown-away.mov", bytes: large)
    let cache = temp.makeFile(".cache/huggingface/hub/models--org--name/weights", bytes: large)
    let git = temp.makeFile("dev/app/.git/objects/pack/big.pack", bytes: large)
    let hiddenFile = temp.makeFile("Documents/.hidden-render.mov", bytes: large)
    let visible = temp.makeFile("Documents/render.mov", bytes: large)

    let items = await LargeFilesScanner().scan(context(
        temp: temp, answering: [trashed, cache, git, hiddenFile, visible]))

    // A hidden component means somebody's tool state — and `~/.Trash` is a list of things
    // the user has already thrown away, which they must not be asked about again.
    #expect(items.map(\.method) == [.removePath(canonical(visible))])
}

@Test func nothingInsideAnApplicationBundleOrOtherPackageIsEverOffered() async {
    let temp = TempDir()
    let inApp = temp.makeFile(
        "Applications/DevCleaner.app/Contents/MacOS/DevCleaner", bytes: large)
    let inPhotos = temp.makeFile(
        "Pictures/Photos Library.photoslibrary/originals/0/IMG.mov", bytes: large)
    let inArchive = temp.makeFile(
        "Documents/App.xcarchive/dSYMs/App.app.dSYM/Contents/big", bytes: large)
    let loose = temp.makeFile("Documents/render.mov", bytes: large)

    let items = await LargeFilesScanner().scan(context(
        temp: temp, answering: [inApp, inPhotos, inArchive, loose]))

    // A frame inside a Photos library is not a file the user can answer about: removing it
    // corrupts the library rather than freeing space they chose to give up. Every ancestor
    // is read, which is why the extension list and not `URL.isPackage` decides.
    #expect(items.map(\.method) == [.removePath(canonical(loose))])
    #expect(LargeFileLicence.packageExtensions.contains("app"))
    #expect(LargeFileLicence.packageExtensions.contains("photoslibrary"))
    // Lower-cased on both sides, so `.dSYM` and `.DSYM` are one kind of thing.
    #expect(LargeFileLicence.packageExtensions.contains("dsym"))
}

// MARK: - the cap

/// Biggest first, and never more than a page the user could read.
///
/// Over the pure function rather than over fixtures, because the honest version of this
/// test needs 201 files past the floor and the assertion is about ordering and counting
/// rather than about the disk.
@Test func atMostTwoHundredRowsSurviveAndTheyAreTheBiggest() {
    let found = (1...250).map {
        LargeFileLicence(path: "/Users/tester/Documents/f\($0)", sizeBytes: Int64($0) * 1_000,
                         modified: nil)
    }

    let kept = LargeFilesScanner.biggestFirst(found)

    #expect(LargeFilesScanner.maximumRows == 200)
    #expect(kept.count == 200)
    #expect(kept.first?.sizeBytes == 250_000)
    // The cap cut the smallest fifty, which is the only direction it may cut in.
    #expect(kept.last?.sizeBytes == 51_000)
}

/// Ties broken by path, so one scan dealt twice is the same page and the checkboxes do not
/// move under the cursor.
@Test func rowsOfEqualSizeAreOrderedByPathSoThePageIsStable() {
    let found = ["/b", "/a", "/c"].map {
        LargeFileLicence(path: $0, sizeBytes: 1_000, modified: nil)
    }
    #expect(LargeFilesScanner.biggestFirst(found).map(\.path) == ["/a", "/b", "/c"])
}

// MARK: - the licence, asked directly

/// The refusals stated at the level of the rule itself, so a change to it fails here as
/// well as in the two places that ask it.
@Test func theLicenceAnswersNoForEveryPathThatMustNeverBeRemoved() {
    let temp = TempDir()
    let home = temp.path
    let file = temp.makeFile("Documents/render.mov", bytes: large)
    let manager = FileManager.default

    func granted(_ path: String) -> LargeFileLicence? {
        LargeFileLicence.granted(for: path, home: home, fileManager: manager)
    }

    #expect(granted(file)?.path == canonical(file))
    #expect(granted(file)?.sizeBytes == large)
    // Relative, and the empty path.
    #expect(granted("Documents/render.mov") == nil)
    #expect(granted("") == nil)
    // A parent that does not exist: nothing to canonicalise, so nothing to check.
    #expect(granted(home + "/nope/render.mov") == nil)
    // The home folder itself is not under the home folder.
    #expect(granted(home) == nil)
    // Separator-aware, so a home of `/Users/x` does not admit `/Users/xavier`.
    #expect(LargeFileLicence.granted(
        for: file, home: home + "-other", fileManager: manager) == nil)
    // A home that cannot be resolved licences nothing at all.
    #expect(LargeFileLicence.granted(
        for: file, home: home + "/missing", fileManager: manager) == nil)
}

/// **A symlink is judged as itself, never as the file it points at.**
///
/// Both halves are asserted because only one of them is doing the work today, and it is not
/// the one the rule is written for. `attributesOfItem` is `lstat`-shaped: the link answers
/// `typeSymbolicLink` and ninety-nine bytes — the length of the path it holds — so the floor
/// alone would refuse it even with the kind ignored.
///
/// Swap that read for anything `stat`-shaped, such as
/// `URL.resourceValues(forKeys: [.fileSizeKey])` or an `attributesOfItem` of the resolved
/// path, and the same link answers 1.7 GB and `typeRegular`. The kind is then the only rule
/// standing between a checkbox and a link into somebody's photo library — where the row
/// promises 1.7 GB and trashing the link frees nothing whatever. So the sizes are pinned
/// here beside the verdict: a reader who changes how the size is read can see from this test
/// which rule they have just made load-bearing.
@Test func aSymlinkIsJudgedAsItselfAndNeverAsTheFileItPointsAt() throws {
    let temp = TempDir()
    let film = temp.makeFile("Documents/films/holiday.mov", bytes: large)
    let link = temp.makeSymlink("Documents/films/shortcut.mov", to: film)
    let manager = FileManager.default

    // The same path, judged twice, and the answers differ — which is the property. Nothing
    // about the link's *target* leaks into the verdict about the link.
    #expect(LargeFileLicence.granted(for: film, home: temp.path, fileManager: manager)?
            .sizeBytes == large)
    #expect(LargeFileLicence.granted(for: link, home: temp.path, fileManager: manager) == nil)

    // And the reason it differs, so the redundancy above is visible rather than assumed.
    let attributes = try manager.attributesOfItem(atPath: link)
    #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    #expect((attributes[.size] as? NSNumber)?.int64Value ?? 0 < LargeFileLicence.minimumBytes)
    // A directory answers the same way, for the same reason: its own inode is 64 bytes, not
    // the size of the tree a row that claimed to be one file would take with it.
    let folder = temp.makeDirectory("Documents/films/a folder.mov")
    #expect(try manager.attributesOfItem(atPath: folder)[.type] as? FileAttributeType
            == .typeDirectory)
    #expect(LargeFileLicence.granted(for: folder, home: temp.path, fileManager: manager) == nil)
}

/// A row earns the licence only under this scanner's identifier, and only for its own path.
@Test func onlyBigLargeFilesRowsContributeAnExactPathToTheRunGuard() {
    let temp = TempDir()
    let file = temp.makeFile("Documents/render.mov", bytes: large)
    let sibling = temp.makeFile("Documents/keep-this.mov", bytes: large)

    let mine = ScanHelpers.item(
        scannerID: LargeFilesScanner.scannerID, group: .bigThings, path: file,
        name: "render.mov", sizeBytes: large, risk: .irreplaceable, startsUnticked: true)
    let forged = ScanHelpers.item(
        scannerID: "projects.buildOutput", group: .projects, path: sibling,
        name: "keep-this.mov", sizeBytes: large)

    let allowed = LargeFileLicence.allowedExactPaths(
        for: [mine, forged], home: temp.path, fileManager: .default)

    // One path, exactly. The other row's path earns nothing, and neither row's *folder*
    // earns anything: the home folder never becomes a root.
    #expect(allowed == [canonical(file)])
}
