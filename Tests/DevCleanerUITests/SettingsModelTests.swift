import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

private func model(_ change: (inout Settings) -> Void = { _ in }) -> SettingsModel {
    var settings = Settings.makeDefault(home: "/Users/test")
    change(&settings)
    return SettingsModel(settings: settings, home: "/Users/test")
}

// MARK: - project roots

@Test func aProjectRootCanBeAddedAndRemoved() {
    var settings = model()
    settings.addProjectRoot("/Users/test/work")
    #expect(settings.draft.projectRoots == ["/Users/test/dev", "/Users/test/work"])
    #expect(settings.isDirty)

    settings.removeProjectRoot("/Users/test/dev")
    #expect(settings.draft.projectRoots == ["/Users/test/work"])
}

@Test func anEmptyOrDuplicateProjectRootIsRefusedWithAReason() {
    var settings = model()
    settings.addProjectRoot("   ")
    #expect(settings.message != nil)
    #expect(settings.draft.projectRoots == ["/Users/test/dev"])

    settings.addProjectRoot("/Users/test/dev")
    #expect(settings.message?.contains("already") == true)
    #expect(settings.draft.projectRoots == ["/Users/test/dev"])
}

/// The value stored is the trimmed one, and the duplicate check is made against the trimmed
/// one too. A trailing space is invisible in a text field, so `~/dev ` stored beside `~/dev`
/// is two roots the user cannot tell apart and one of them is walked twice.
@Test func aProjectRootIsStoredTrimmedAndComparedTrimmed() {
    var settings = model()
    settings.addProjectRoot("  /Users/test/work  ")
    #expect(settings.draft.projectRoots == ["/Users/test/dev", "/Users/test/work"])

    settings.addProjectRoot("  /Users/test/dev  ")
    #expect(settings.message?.contains("already") == true)
    #expect(settings.draft.projectRoots == ["/Users/test/dev", "/Users/test/work"])
}

/// `~/work` is the form a user types, so it is accepted — a stricter rule here, "must start
/// with /", would refuse a root the engine is happy to store and make the field unusable.
///
/// It is **stored expanded**, in this draft, right away. `SettingsStore.load` expands too,
/// but the draft is what the window shows and what the pin list walks, and neither waits for
/// a save and a reload: stored as typed, the root the user just added would list no projects
/// until the app was restarted.
///
/// Expanded through `TildePath`, the engine's own rule, so the value on screen and the value
/// the engine walks cannot disagree about which directory `~/work` names.
@Test func aTildeProjectRootIsStoredExpandedThroughTheEnginesOwnRule() {
    var settings = model()
    settings.addProjectRoot("~/work")

    #expect(settings.draft.projectRoots == ["/Users/test/dev", "/Users/test/work"])
    #expect(settings.message == nil)
    #expect(settings.isDirty)
}

/// The shapes `TildePath` leaves alone are left alone here too, so the refusal the user
/// reads quotes what they typed. A bare `~` is the one the engine's message is written
/// around; `~someoneelse/dev` names a home no injected home can resolve.
@Test func theTildeShapesTheEngineLeavesAloneAreStoredAsTyped() {
    var settings = model()
    settings.addProjectRoot("~")
    settings.addProjectRoot("~someoneelse/dev")
    settings.addProjectRoot("/tmp/~foo")

    #expect(settings.draft.projectRoots
        == ["/Users/test/dev", "~", "~someoneelse/dev", "/tmp/~foo"])
}

/// Expanding before the duplicate check means the two ways of writing one folder are one
/// entry. Stored as typed, `~/dev` and `/Users/test/dev` are two roots, and the walk runs
/// twice over the same projects.
@Test func aTildeRootThatNamesAnExistingRootIsRefusedAsADuplicate() {
    var settings = model()
    settings.addProjectRoot("~/dev")

    #expect(settings.message == "/Users/test/dev is already a project root.")
    #expect(settings.draft.projectRoots == ["/Users/test/dev"])
    #expect(!settings.isDirty)
}

/// The engine refuses `~`, `/` and any ancestor of home. The app must show the refusal
/// rather than dropping the value silently — and must keep the value in the draft so the
/// user can see what was rejected and fix it.
@Test func aTooWideProjectRootIsShownRatherThanSwallowed() {
    var settings = model()
    var engine = FakeEngine()
    engine.saveError = SettingsError.projectRootTooWide("~")

    settings.addProjectRoot("~")
    // The call is made outside `#expect`: the macro passes the receiver as an immutable
    // value, so a `mutating` method inside it does not compile.
    let saved = settings.save(with: engine)

    #expect(!saved)
    #expect(settings.message == SettingsError.projectRootTooWide("~").description)
    #expect(settings.draft.projectRoots.contains("~"))
    #expect(settings.isDirty)
}

/// Not every refusal is a project root. A write that fails because the directory is not
/// writable must still say so out loud: a silent `catch` here is the phase-1 bug wearing a
/// different coat, and the settings it drops include the two pins that keep a device from a
/// permanent delete.
@Test func aSaveThatFailsForAnotherReasonStillShowsAMessage() {
    var settings = model()
    var engine = FakeEngine()
    engine.saveError = CocoaError(.fileWriteNoPermission)

    settings.setPinnedSimulator("AAA")
    let saved = settings.save(with: engine)

    #expect(!saved)
    #expect(settings.message?.contains("could not be saved") == true)
    #expect(settings.isDirty)
    #expect(settings.draft.pinnedSimulatorUDID == "AAA")
}

/// The save path needs the same rule as the setter path: a refusal must not outlive the
/// value it refused. The user hits a permission error, fixes it, saves again — and without
/// this the old sentence sits beside a value that was in fact stored.
///
/// `aSuccessfulSaveClearsTheMessageAndTheDirtyFlag` cannot see this: it calls a setter
/// first, and the setter has already cleared the message.
@Test func aSaveThatSucceedsAfterAFailureClearsTheOldRefusal() {
    var settings = model()
    var engine = FakeEngine()
    engine.saveError = CocoaError(.fileWriteNoPermission)

    settings.setPinnedSimulator("AAA")
    let refused = settings.save(with: engine)
    #expect(!refused)
    #expect(settings.message != nil)

    engine.saveError = nil
    let stored = settings.save(with: engine)

    #expect(stored)
    #expect(settings.message == nil)
    #expect(!settings.isDirty)
}

@Test func aSuccessfulSaveClearsTheMessageAndTheDirtyFlag() {
    var settings = model()
    settings.addProjectRoot("/Users/test/work")
    let saved = settings.save(with: FakeEngine())

    #expect(saved)
    #expect(settings.message == nil)
    #expect(!settings.isDirty)
}

// MARK: - numbers

@Test func aThresholdThatIsNotAWholeNumberIsRefusedAndTheOldValueStands() {
    var settings = model()
    settings.setActiveThresholdDays("fourteen")

    #expect(settings.draft.activeThresholdDays == 14)
    #expect(settings.message?.contains("whole number") == true)
    #expect(!settings.isDirty)
}

@Test func aThresholdBelowItsFloorIsRefused() {
    var settings = model()
    settings.setActiveThresholdDays("0")
    #expect(settings.draft.activeThresholdDays == 14)
    #expect(settings.message?.contains("at least 1") == true)

    settings.setBackgroundScanIntervalHours("0")
    #expect(settings.draft.backgroundScanIntervalHours == 6)
}

/// Zero is an answer for these two; below zero is not. A device recent-use of -1 puts the
/// cutoff in the future, so nothing counts as recently used and a simulator booted this
/// morning is offered for a delete that has no Trash behind it.
@Test func aNegativeNumberIsRefusedEvenWhereZeroIsAllowed() {
    var settings = model()
    settings.setDeviceRecentUseDays("-1")

    #expect(settings.draft.deviceRecentUseDays == 7)
    #expect(settings.message?.contains("at least 0") == true)
    #expect(!settings.isDirty)
}

@Test func theFourNumericSettingsAllAccept() {
    var settings = model()
    settings.setActiveThresholdDays("21")
    settings.setDeviceRecentUseDays("3")
    settings.setArchiveAgeDays("60")
    settings.setBackgroundScanIntervalHours("12")

    #expect(settings.draft.activeThresholdDays == 21)
    #expect(settings.draft.deviceRecentUseDays == 3)
    #expect(settings.draft.archiveAgeDays == 60)
    #expect(settings.draft.backgroundScanIntervalHours == 12)
    #expect(settings.message == nil)
}

/// Zero days is a real answer for these two: "protect only the device I am in right now",
/// "delete every archive". One is not a floor here.
@Test func zeroIsAllowedForTheTwoSettingsWhereItMeansSomething() {
    var settings = model()
    settings.setDeviceRecentUseDays("0")
    settings.setArchiveAgeDays("0")

    #expect(settings.draft.deviceRecentUseDays == 0)
    #expect(settings.draft.archiveAgeDays == 0)
    #expect(settings.message == nil)
}

/// Each refusal names the setting it refused, in full and not by substring.
///
/// Four fields share one validator, so the name is a parameter, and a parameter that is
/// ignored still produces a plausible sentence: "Active threshold must be at least 0" beside
/// the archive box sends the user to correct a field that was never wrong. Substring checks
/// on "whole number" and "at least 0" pass whatever name is printed.
@Test func eachRefusalNamesTheSettingItRefused() {
    var settings = model()
    settings.setActiveThresholdDays("x")
    #expect(settings.message == "Active threshold must be a whole number, not \"x\".")

    settings.setDeviceRecentUseDays("-1")
    #expect(settings.message == "Device recent use must be at least 0.")

    settings.setArchiveAgeDays("-2")
    #expect(settings.message == "Archive age must be at least 0.")

    settings.setBackgroundScanIntervalHours("soon")
    #expect(settings.message == "Background scan interval must be a whole number, not \"soon\".")
}

/// A refusal must not outlive the value it refused. Left on screen beside a value that was
/// accepted, the sentence tells the user their change was thrown away when it was stored.
@Test func aValueThatIsAcceptedClearsTheEarlierRefusal() {
    var settings = model()
    settings.setActiveThresholdDays("fourteen")
    #expect(settings.message != nil)

    settings.setActiveThresholdDays("21")
    #expect(settings.message == nil)
    #expect(settings.draft.activeThresholdDays == 21)
}

// MARK: - the rest of §8.4

@Test func aScannerCanBeSwitchedOffAndOnAgain() {
    var settings = model()
    settings.setSkipped("flutter.pubCache", true)
    #expect(settings.draft.isSkipped("flutter.pubCache"))

    settings.setSkipped("flutter.pubCache", false)
    #expect(!settings.draft.isSkipped("flutter.pubCache"))
}

/// The stored identifiers keep the registry's order, so a settings file stays readable
/// and two machines with the same switches produce the same file.
@Test func skippedScannersAreStoredInRegistryOrder() {
    var settings = model()
    settings.setSkipped("other.libraryCaches", true)
    settings.setSkipped("xcode.archives", true)

    #expect(settings.draft.alwaysSkipScannerIDs == ["xcode.archives", "other.libraryCaches"])
}

/// An identifier this build does not recognise is kept, after the ones it does.
///
/// It cannot do any harm — `Settings.isSkipped` is a plain `contains`, so an unknown entry
/// switches nothing on. Dropping it can: a scanner renamed between versions, or a downgrade
/// to a build that predates one, would mean flipping any single switch quietly rewrites the
/// file without a skip the user chose and never withdrew.
/// Two unknown entries, in an order that is neither alphabetical nor the registry's, so the
/// fixture separates "kept in file order" from "sorted" and from "whatever the set hashed
/// to".
@Test func anUnknownScannerIDIsKeptRatherThanQuietlyDropped() {
    var settings = model {
        $0.alwaysSkipScannerIDs = ["xcode.renamedLastVersion", "other.libraryCaches",
                                   "aardvark.retired"]
    }
    settings.setSkipped("xcode.archives", true)

    #expect(settings.draft.alwaysSkipScannerIDs == [
        "xcode.archives", "other.libraryCaches",
        "xcode.renamedLastVersion", "aardvark.retired",
    ])
}

@Test func devicesAndProjectsCanBePinnedAndUnpinned() {
    var settings = model()
    settings.setPinnedSimulator("AAA")
    settings.setPinnedAVD("sample_avd")
    settings.setPinned("/Users/test/dev/sample-project", true)

    #expect(settings.draft.pinnedSimulatorUDID == "AAA")
    #expect(settings.draft.pinnedAVDName == "sample_avd")
    #expect(settings.draft.pinnedProjectPaths == ["/Users/test/dev/sample-project"])

    settings.setPinnedSimulator(nil)
    settings.setPinned("/Users/test/dev/sample-project", false)
    #expect(settings.draft.pinnedSimulatorUDID == nil)
    #expect(settings.draft.pinnedProjectPaths.isEmpty)
}

/// Pinned paths are stored in path order for the same reason the skipped identifiers are
/// stored in registry order: a set written out in whatever order it happened to hash makes
/// a diff of `settings.json` unreadable, and the pins are the entries worth reading.
///
/// Six paths ticked in a scrambled order, not two. `Array(Set)` matches a two-entry sorted
/// list about half the time — Swift seeds its hashing per process — so a two-entry fixture
/// says "sorted" while proving nothing. Six leaves one arrangement in 720.
@Test func pinnedProjectPathsAreStoredInPathOrder() {
    var settings = model()
    for path in ["sample-project", "atlas", "mimir", "borea", "yak", "cove"] {
        settings.setPinned("/Users/test/dev/" + path, true)
    }

    #expect(settings.draft.pinnedProjectPaths == [
        "/Users/test/dev/atlas", "/Users/test/dev/borea", "/Users/test/dev/cove",
        "/Users/test/dev/mimir", "/Users/test/dev/sample-project", "/Users/test/dev/yak",
    ])
}

/// Registry order, whatever order the switches were flipped in — and six of them, for the
/// reason above: two entries cannot tell a list that was ordered from a set that happened
/// to come out that way. Alphabetical order of these six is a different list again
/// (`android.avds` first, `xcode.derivedData` last), so this fixture separates all three.
@Test func skippedScannersKeepRegistryOrderWhicheverOrderTheyAreSwitchedOff() {
    var settings = model()
    for id in ["other.libraryCaches", "xcode.derivedData", "projects.buildOutput",
               "ios.runtimes", "flutter.fvm", "android.avds"] {
        settings.setSkipped(id, true)
    }

    #expect(settings.draft.alwaysSkipScannerIDs == [
        "xcode.derivedData", "ios.runtimes", "android.avds", "flutter.fvm",
        "projects.buildOutput", "other.libraryCaches",
    ])
}

@Test func theThreeSwitchesFlip() {
    var settings = model()
    settings.setMoveToTrash(false)
    settings.setMenuBarShowsAmount(false)
    settings.setLaunchAtLogin(true)

    #expect(!settings.draft.moveToTrash)
    #expect(!settings.draft.menuBarShowsAmount)
    #expect(settings.draft.launchAtLogin)
}

/// Every setter writes its own field, and every setter raises `isDirty`.
///
/// `isDirty` is what the Save button reads, so a setter that does not raise it is a change
/// the user can make and cannot store — and a pinned simulator that never reaches the file
/// is a device the next default clean deletes for good.
///
/// The field is checked here as well as the flag, on a fresh model each time, because a pair
/// of setters that write each other's field is invisible to a test that flips both switches
/// on one model and then asserts both: `setMoveToTrash(false)` writing `menuBarShowsAmount`
/// leaves both booleans exactly where a swapped pair would.
@Test func everySetterStoresItsOwnValueAndMarksTheDraftDirty() {
    let setters: [(name: String, apply: (inout SettingsModel) -> Void,
                   stored: (SettingsModel) -> Bool)] = [
        ("addProjectRoot", { $0.addProjectRoot("/Users/test/work") },
         { $0.draft.projectRoots == ["/Users/test/dev", "/Users/test/work"] }),
        ("removeProjectRoot", { $0.removeProjectRoot("/Users/test/dev") },
         { $0.draft.projectRoots.isEmpty }),
        ("setActiveThresholdDays", { $0.setActiveThresholdDays("21") },
         { $0.draft.activeThresholdDays == 21 }),
        ("setDeviceRecentUseDays", { $0.setDeviceRecentUseDays("3") },
         { $0.draft.deviceRecentUseDays == 3 }),
        ("setArchiveAgeDays", { $0.setArchiveAgeDays("60") },
         { $0.draft.archiveAgeDays == 60 }),
        ("setBackgroundScanIntervalHours", { $0.setBackgroundScanIntervalHours("12") },
         { $0.draft.backgroundScanIntervalHours == 12 }),
        ("setSkipped", { $0.setSkipped("flutter.pubCache", true) },
         { $0.draft.alwaysSkipScannerIDs == ["flutter.pubCache"] }),
        ("setPinnedSimulator", { $0.setPinnedSimulator("AAA") },
         { $0.draft.pinnedSimulatorUDID == "AAA" }),
        ("setPinnedAVD", { $0.setPinnedAVD("sample_avd") },
         { $0.draft.pinnedAVDName == "sample_avd" }),
        ("setPinned", { $0.setPinned("/Users/test/dev/sample-project", true) },
         { $0.draft.pinnedProjectPaths == ["/Users/test/dev/sample-project"] }),
        ("setMoveToTrash", { $0.setMoveToTrash(false) },
         { !$0.draft.moveToTrash && $0.draft.menuBarShowsAmount && !$0.draft.launchAtLogin }),
        ("setMenuBarShowsAmount", { $0.setMenuBarShowsAmount(false) },
         { !$0.draft.menuBarShowsAmount && $0.draft.moveToTrash && !$0.draft.launchAtLogin }),
        ("setLaunchAtLogin", { $0.setLaunchAtLogin(true) },
         { $0.draft.launchAtLogin && $0.draft.moveToTrash && $0.draft.menuBarShowsAmount }),
    ]

    for setter in setters {
        var settings = model()
        setter.apply(&settings)
        #expect(settings.isDirty, "\(setter.name) left the draft looking unchanged")
        #expect(setter.stored(settings), "\(setter.name) did not store its own value")
    }
}

// MARK: - the pickers

@Test func theSimulatorAndEmulatorChoicesComeFromTheScanIncludingProtectedOnes() {
    let result = makeResult([
        makeItem(id: "s1", group: .xcodeAndIOS, name: "iPhone 17",
                 sizeBytes: 12_860_000_000, method: .deleteSimulator(udid: "AAA")),
        makeItem(id: "s2", group: .xcodeAndIOS, name: "Sample Design Simulator",
                 sizeBytes: 7_080_000_000, protection: .bootedDevice,
                 method: .deleteSimulator(udid: "BBB")),
        // The display name is deliberately not the AVD name. `Settings.pinnedAVDName` stores
        // the identifier out of `.deleteAVD(name:)`, and a fixture where the two strings
        // match cannot tell that field from `CleanupItem.name` — so a picker that pinned the
        // label instead of the identifier would look right and protect nothing.
        makeItem(id: "a1", group: .android, name: "Pixel 8 API 35", sizeBytes: 4_130_000_000,
                 protection: .mostRecentlyUsedDevice, method: .deleteAVD(name: "sample_avd")),
        makeItem(id: "path", group: .otherCaches, name: "Yarn"),
    ])

    let simulators = PickerChoices.simulators(in: result)
    #expect(simulators.map(\.id) == ["AAA", "BBB"])
    #expect(simulators.last?.name == "Sample Design Simulator")
    #expect(simulators.last?.isKept == true)
    #expect(simulators.first?.sizeText == "12.9 GB")
    #expect(simulators.first?.isKept == false)

    let emulators = PickerChoices.emulators(in: result)
    #expect(emulators.map(\.id) == ["sample_avd"])
    #expect(emulators.first?.name == "Pixel 8 API 35")
    #expect(emulators.first?.sizeText == "4.1 GB")
    #expect(emulators.first?.isKept == true)
}

@Test func theProjectChoicesComeFromDiscoveryAndSkipRootsTheEngineRefused() {
    let temp = TempDir()
    temp.write("dev/sample-project/pubspec.yaml", "name: sample-project")
    temp.write("dev/atlas/package.json", "{}")
    temp.write("wide/anything/package.json", "{}")

    let choices = PickerChoices.projects(
        roots: [temp.path + "/dev", temp.path + "/wide"],
        ignoredRoots: [temp.path + "/wide"],
        home: temp.path)

    #expect(choices.map(\.name) == ["atlas", "sample-project"])
    #expect(choices.first?.displayPath == "~/dev/atlas")
    // The id is the absolute path, because it is what `setPinned` stores into
    // `Settings.pinnedProjectPaths` and what the engine matches a project against. An id of
    // the bare name would fill that setting with strings no project path can ever equal, and
    // every pin made through this picker would be silently inert.
    #expect(choices.map(\.id) == [temp.path + "/dev/atlas", temp.path + "/dev/sample-project"])
}

/// Two projects with the same name are two rows.
///
/// The fixture models two projects named `shared-project-name`. De-duplicating by name
/// rather than by path would drop one of them from the list — the user pins what they think
/// is theirs and the other one is deleted — and would also hand SwiftUI two identical ids.
@Test func twoProjectsWithTheSameNameAreBothListed() {
    let temp = TempDir()
    temp.write("dev/one/shared-project-name/pubspec.yaml", "name: app")
    temp.write("dev/two/shared-project-name/pubspec.yaml", "name: app")

    let choices = PickerChoices.projects(
        roots: [temp.path + "/dev"], ignoredRoots: [], home: temp.path)

    #expect(choices.map(\.displayPath)
        == ["~/dev/one/shared-project-name", "~/dev/two/shared-project-name"])
    #expect(Set(choices.map(\.id)).count == 2)
}

/// Path order, not the order the roots happened to be walked in.
///
/// Two roots, the later one sorting first, because two projects inside one directory cannot
/// show the difference: `contentsOfDirectory` returns those two in alphabetical order on
/// a real dev machine, so the sorted list and the unsorted one are the same list and the test
/// proves nothing. With `~/zebra` listed before `~/alpha` in the settings, only a real sort
/// puts `alpha` first — otherwise the checkbox list reshuffles itself when the user adds a
/// root.
@Test func theProjectChoicesAreOrderedByPathNotByTheOrderOfTheRoots() {
    let temp = TempDir()
    temp.write("zebra/wibble/package.json", "{}")
    temp.write("alpha/gadget/package.json", "{}")

    let choices = PickerChoices.projects(
        roots: [temp.path + "/zebra", temp.path + "/alpha"], ignoredRoots: [], home: temp.path)

    #expect(choices.map(\.displayPath) == ["~/alpha/gadget", "~/zebra/wibble"])
}

@Test func theProjectChoicesListEachProjectOnce() {
    let temp = TempDir()
    temp.write("dev/sample-project/pubspec.yaml", "name: sample-project")

    let choices = PickerChoices.projects(
        roots: [temp.path + "/dev", temp.path + "/dev"], ignoredRoots: [], home: temp.path)

    #expect(choices.count == 1)
}
