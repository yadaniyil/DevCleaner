import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

/// The registry is the authority on what scanners exist. A settings screen listing a
/// subset would leave a scanner the user cannot switch off; one listing an identifier the
/// registry does not have would write a value that silently does nothing.
@Test func everyScannerInTheRegistryHasARowAndKeepsItsOrder() {
    let rows = SettingsText.scannerRows()

    #expect(rows.map(\.id) == CleanerService.scannerIDs)
    #expect(rows.count == CleanerService.allScanners().count)
}

@Test func everyScannerRowCarriesTheEnginesOwnTitle() {
    let titles = CleanerService.allScanners().map(\.title)
    #expect(SettingsText.scannerRows().map(\.title) == titles)
    #expect(SettingsText.scannerRows().allSatisfy { !$0.title.isEmpty })
}

@Test func everySectionAndFieldHasAVisibleLabel() {
    let strings = [
        SettingsText.projectRootsTitle, SettingsText.projectRootsHelp,
        SettingsText.addRoot, SettingsText.removeRoot, SettingsText.newRootPrompt,
        SettingsText.keepingTitle, SettingsText.activeThreshold, SettingsText.deviceRecentUse,
        SettingsText.archiveAge,
        SettingsText.pinnedProjectsTitle, SettingsText.pinnedProjectsHelp,
        SettingsText.noProjectsYet,
        SettingsText.keptDevicesTitle, SettingsText.automaticDevice,
        SettingsText.simulator, SettingsText.emulator, SettingsText.noDevicesYet,
        SettingsText.scannersTitle, SettingsText.scannersHelp,
        SettingsText.appTitle, SettingsText.backgroundInterval,
        SettingsText.menuBarShowsAmount, SettingsText.moveToTrash, SettingsText.moveToTrashHelp,
        SettingsText.save,
    ]
    #expect(strings.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
}

/// The one switch that changes whether anything can be got back.
@Test func theTrashSwitchExplainsWhatTurningItOffCosts() {
    #expect(SettingsText.moveToTrashHelp.contains("cannot"))
    #expect(SettingsText.moveToTrashHelp.contains("Trash"))
    // And it must not promise that devices obey it.
    #expect(SettingsText.moveToTrashHelp.contains("Simulators"))
    // The other rule the switch does not reach, and it points the opposite way: one of the
    // user's own large files is always trashed, because there would be nothing anywhere to
    // get it back from. A user who turns this off and reads nothing about that has been
    // left believing they signed up for something the app will never do.
    #expect(SettingsText.moveToTrashHelp.contains("always go to the Trash either way"))
}

@Test func theKeptDevicePickerOffersTheAutomaticChoiceFirst() {
    #expect(SettingsText.automaticDevice == "Most recently used")
}

/// Devices and projects are listed from the last scan. Before there is one, the sections
/// say why they are empty rather than looking broken.
///
/// They send the user to the button that exists, by the name it really has. The menu bar's
/// "Rescan" went with the checklist; the control is `ProjectDeckText.scanAgain`, in the
/// window's toolbar and on the menu bar panel, so an instruction naming the old one points
/// at nothing on screen.
@Test func theEmptyPickerSentencesPointAtARescan() {
    #expect(SettingsText.noProjectsYet.contains(ProjectDeckText.scanAgain))
    #expect(SettingsText.noDevicesYet.contains(ProjectDeckText.scanAgain))
    #expect(!SettingsText.noProjectsYet.contains("Rescan"))
}

// MARK: - labels that could be copied into the wrong row

/// Four fields sit two sections apart and four of them are bare numbers with a unit beside
/// them. A label reused on the wrong row sends the user to correct a setting that was never
/// wrong — and `deviceRecentUse` is the one that decides which simulator survives a delete
/// with no Trash behind it.
///
/// `days` and `hours` are here because nothing else looks at them: the whole-label test
/// above does not list them, so `hours = "days"` would otherwise print "Scan again every 6
/// days" with every test still green.
@Test func noTwoLabelsInTheWindowSayTheSameThing() {
    let labels = [
        SettingsText.activeThreshold, SettingsText.deviceRecentUse, SettingsText.archiveAge,
        SettingsText.backgroundInterval, SettingsText.days, SettingsText.hours,
        SettingsText.simulator, SettingsText.emulator,
        SettingsText.addRoot, SettingsText.removeRoot, SettingsText.save,
        SettingsText.noProjectsYet, SettingsText.noDevicesYet,
    ]

    #expect(Set(labels).count == labels.count)
    #expect(labels.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
}

// MARK: - the two device pickers

/// A device row has to say which device and what it costs. Two simulators on a real dev machine
/// are both called `iPhone 17`; the size is what tells them apart in the picker.
///
/// `isKept` is a snapshot of the **last scan**, not live truth, so the row says so in the
/// past tense. "kept" alone reads as a promise about right now, which nothing here can make.
@Test func aDeviceRowNamesTheDeviceItsSizeAndWhetherTheLastScanKeptIt() {
    let free = DeviceChoice(id: "AAA", name: "iPhone 17", sizeText: "12.9 GB", isKept: false)
    let kept = DeviceChoice(
        id: "BBB", name: "Sample Design Simulator", sizeText: "7.1 GB", isKept: true)

    #expect(SettingsText.deviceLabel(free) == "iPhone 17 — 12.9 GB")
    #expect(SettingsText.deviceLabel(kept)
        == "Sample Design Simulator — 7.1 GB · kept by the last scan")
}

@Test func eachDevicePickerReadsItsOwnRows() {
    let result = makeResult([
        makeItem(id: "s1", name: "iPhone 17", sizeBytes: 12_860_000_000,
                 method: .deleteSimulator(udid: "AAA")),
        makeItem(id: "a1", name: "Pixel 8 API 35", sizeBytes: 4_130_000_000,
                 method: .deleteAVD(name: "sample_avd")),
    ])

    #expect(DeviceKind.simulator.choices(in: result).map(\.id) == ["AAA"])
    #expect(DeviceKind.emulator.choices(in: result).map(\.id) == ["sample_avd"])
    // No scan yet is no rows, not a crash and not a stand-in result invented by the view.
    #expect(DeviceKind.simulator.choices(in: nil).isEmpty)
    #expect(DeviceKind.simulator.label != DeviceKind.emulator.label)
}

/// A picker is empty when its own scanner is switched off, because the list comes from the
/// scan result. "Rescan to list them" is then advice that cannot work: the rescan skips the
/// same scanner and the picker is empty again.
///
/// Both kinds are asked of the same result, so a pair of pickers reading each other's
/// switch — which would say "switched off" beside the emulators the scan did measure —
/// fails here.
@Test func switchingOffOneDeviceScannerOnlySpeaksForItsOwnPicker() {
    let scanned = makeResult([], skipped: [DeviceKind.simulator.scannerID])

    let simulators = SettingsText.deviceNote(
        .simulator, choices: [], result: scanned, pinned: nil)
    let emulators = SettingsText.deviceNote(
        .emulator, choices: [], result: scanned, pinned: nil)

    #expect(simulators == SettingsText.deviceScannerIsOff(.simulator))
    #expect(simulators != SettingsText.noDevicesYet)
    #expect(emulators == SettingsText.noDevicesYet)
}

/// The switch the note blames is a switch the scanners section really offers. An identifier
/// written out here by hand would name a switch that does not exist, and the sentence would
/// send the user looking for it.
@Test func eachDevicePickerNamesAScannerTheRegistryHas() {
    #expect(CleanerService.scannerIDs.contains(DeviceKind.simulator.scannerID))
    #expect(CleanerService.scannerIDs.contains(DeviceKind.emulator.scannerID))
    #expect(DeviceKind.simulator.scannerID != DeviceKind.emulator.scannerID)
}

/// The two identifiers themselves, as literals.
///
/// "Both are real and both differ" is true of any two scanners in the registry, so a
/// `.simulator` pointing at `xcode.archives` passes every other test here while the note
/// blames a switch that has nothing to do with simulators. These are also the strings
/// `Settings.alwaysSkipScannerIDs` and `ScanResult.skippedScannerIDs` store, so a change to
/// either is a change to a stored setting and has to be made on purpose.
@Test func eachDevicePickerNamesTheScannerThatReallyListsThatKind() {
    #expect(DeviceKind.simulator.scannerID == "ios.simulators")
    #expect(DeviceKind.emulator.scannerID == "android.avds")
}

/// The sentence itself, not merely "it is not the other one".
///
/// Every other assertion about `deviceScannerIsOff` compares its output to its own output,
/// so `deviceScannerIsOff(_:) -> ""` satisfies all of them — `"" == ""` passes, and
/// `hasPrefix("")` is always true — and the whole suite stays green while the sentence
/// disappears from the window. That sentence is the entire answer to an empty picker.
@Test func theSwitchedOffSentenceNamesThePickerAndWhereTheSwitchIs() {
    let simulators = SettingsText.deviceScannerIsOff(.simulator)
    let emulators = SettingsText.deviceScannerIsOff(.emulator)

    #expect(simulators.contains(SettingsText.simulator))
    #expect(simulators.contains(SettingsText.scannersTitle))
    #expect(emulators.contains(SettingsText.emulator))
    #expect(emulators.contains(SettingsText.scannersTitle))
    // A version that ignores its argument would say "Simulator" beside the emulator picker.
    #expect(simulators != emulators)
    #expect(!simulators.contains(SettingsText.emulator))
    // And it is not `noDevicesYet` with something stuck on the end: that sentence asks for a
    // rescan, which is the advice this one exists to replace.
    #expect(!simulators.contains(SettingsText.noDevicesYet))
}

/// The bare identifier would be a UDID printed under a picker with no explanation, which
/// says nothing about whether the pin survived. Reduced to that, the sentence still contains
/// the id and still passes a `contains("AAA")` check.
@Test func theMissingPinSentenceSaysThePinIsStillThere() {
    let sentence = SettingsText.pinnedDeviceIsMissing("AAA")

    #expect(sentence.contains("AAA"))
    #expect(sentence.contains("pinned"))
    #expect(sentence.contains("kept"))
}

@Test func aPickerWithNoScanBehindItAsksForOne() {
    #expect(SettingsText.deviceNote(.emulator, choices: [], result: nil, pinned: nil)
        == SettingsText.noDevicesYet)
}

/// A pin the last scan did not list leaves the picker showing nothing selected, which reads
/// as "no device is pinned" — and the pinned simulator is the one thing standing between a
/// device and `simctl delete`, which has no Trash. The note names the stored value instead.
@Test func aPinTheLastScanDidNotListIsNamedRatherThanLookingLost() {
    let rows = [DeviceChoice(id: "BBB", name: "iPhone 17", sizeText: "12.9 GB", isKept: false)]
    let scanned = makeResult([])

    let missing = SettingsText.deviceNote(
        .simulator, choices: rows, result: scanned, pinned: "AAA")
    let listed = SettingsText.deviceNote(
        .simulator, choices: rows, result: scanned, pinned: "BBB")
    let unpinned = SettingsText.deviceNote(
        .simulator, choices: rows, result: scanned, pinned: nil)

    #expect(missing == SettingsText.pinnedDeviceIsMissing("AAA"))
    #expect(missing?.contains("AAA") == true)
    // Nothing is said when the pin is one of the rows, or when there is no pin at all.
    #expect(listed == nil)
    #expect(unpinned == nil)
}

/// Both facts at once: the scanner is off **and** the pin the user made is still stored.
/// Dropping the second half here is what makes a settings window look like it lost a
/// setting it did not lose.
@Test func anEmptyPickerWithAPinBehindItSaysBothThings() {
    let scanned = makeResult([], skipped: [DeviceKind.simulator.scannerID])

    let note = SettingsText.deviceNote(
        .simulator, choices: [], result: scanned, pinned: "AAA")

    #expect(note?.hasPrefix(SettingsText.deviceScannerIsOff(.simulator)) == true)
    #expect(note?.hasSuffix(SettingsText.pinnedDeviceIsMissing("AAA")) == true)
}

// MARK: - the project pin list

/// The roots are handed over as the **stored strings themselves**.
///
/// `ScanResult.ignoredProjectRoots` holds raw `Settings.projectRoots` entries and the two
/// are matched as text, so any transform on the way past — abbreviating for display,
/// expanding a tilde, resolving a symlink — breaks the match and the root the engine refused
/// as too wide is walked anyway. For `~` that is the whole home directory, four levels deep.
///
/// Tilde roots are in the fixture because this function must not touch them. A bare `~` is
/// the shape that really survives a hand-edited settings file — `TildePath` leaves it alone
/// on purpose and `SettingsStore.load` never validates the file — and `~/dev` is here as the
/// shape that would be transformed by anyone who added an expansion at this layer instead of
/// the one boundary that has it.
///
/// Asserted on the root list rather than on the projects found, because a walk cannot tell
/// "this root was dropped" apart from "this root held nothing" — under a temporary home both
/// answers are an empty list.
@Test func theRootsHandedToTheWalkAreTheStoredStringsThemselves() {
    // One root under the **process's own** home directory. A transform that consults
    // `NSHomeDirectory()` instead of the injected home — `abbreviatingWithTildeInPath` is the
    // one to hand — is an identity function on a temporary path, so a fixture living only in
    // a temp directory cannot see it at all. Nothing is read from disk here and no directory
    // has to exist: the assertion is that the string comes back as it went in.
    let underRealHome = (NSHomeDirectory() as NSString).appendingPathComponent("dev")
    var draft = Settings.makeDefault(home: "/Users/test")
    draft.projectRoots = ["~/dev", "/Users/test/work", underRealHome, "~"]

    let refused = makeResult([], ignoredRoots: ["~"])

    #expect(PickerChoices.usableRoots(draft: draft, result: refused)
        == ["~/dev", "/Users/test/work", underRealHome])
    // Before the first scan nothing has been refused yet, so nothing is dropped.
    #expect(PickerChoices.usableRoots(draft: draft, result: nil)
        == ["~/dev", "/Users/test/work", underRealHome, "~"])
}

/// The same rule as far as the checkbox list, so the filtered roots really are the ones
/// walked and not merely computed.
@Test func theProjectPinListDropsARootTheEngineRefused() {
    let temp = TempDir()
    temp.write("dev/sample-project/pubspec.yaml", "name: sample-project")
    temp.write("wide/anything/package.json", "{}")

    var draft = Settings.makeDefault(home: temp.path)
    draft.projectRoots = [temp.path + "/dev", temp.path + "/wide"]

    let refused = makeResult([], ignoredRoots: [temp.path + "/wide"])

    #expect(PickerChoices.projects(draft: draft, result: refused, home: temp.path)
        .map(\.name) == ["sample-project"])
    // Before the first scan there is no refusal to honour, so every root is walked. Order is
    // by path, which is what `PickerChoices.projects` sorts by — never the listing order of
    // the directory.
    #expect(PickerChoices.projects(draft: draft, result: nil, home: temp.path)
        .map(\.name) == ["sample-project", "anything"])
}

/// A pin list emptied because every root was refused as too wide is not the same emptiness
/// as no projects found.
///
/// `noProjectsYet` says "Scan again from the DevCleaner window, or add the folder your code
/// is in above" — printed directly under the root that made the list empty, and the next scan
/// refuses that same root again. It is the project section's version of a picker emptied by
/// its own scanner.
@Test func aPinListEmptiedByRefusedRootsSaysSoRatherThanAskingForARescan() {
    var draft = Settings.makeDefault(home: "/Users/test")
    draft.projectRoots = ["~"]
    let refused = makeResult([], ignoredRoots: ["~"])

    #expect(SettingsText.projectNote(choices: [], draft: draft, result: refused)
        == SettingsText.everyProjectRootWasRefused)

    // One usable root left is ordinary emptiness: adding a folder or rescanning does help.
    draft.projectRoots = ["~", "/Users/test/dev"]
    #expect(SettingsText.projectNote(choices: [], draft: draft, result: refused)
        == SettingsText.noProjectsYet)

    // No roots at all is ordinary emptiness too, and "add the folder your code is in" is then
    // exactly the right advice.
    draft.projectRoots = []
    #expect(SettingsText.projectNote(choices: [], draft: draft, result: refused)
        == SettingsText.noProjectsYet)
}

/// Nothing is said when the list has rows, whatever the roots did.
@Test func aPinListWithProjectsInItSaysNothing() {
    var draft = Settings.makeDefault(home: "/Users/test")
    draft.projectRoots = ["~"]
    let rows = [ProjectChoice(
        id: "/Users/test/dev/sample-project", name: "sample-project", displayPath: "~/dev/sample-project")]

    #expect(SettingsText.projectNote(
        choices: rows, draft: draft, result: makeResult([], ignoredRoots: ["~"])) == nil)
}

/// The sentence itself, pinned against something other than itself — the same hole that let
/// `deviceScannerIsOff` be emptied without a test noticing.
@Test func theRefusedRootsSentenceSaysWhatIsWrongAndWhatToTypeInstead() {
    let sentence = SettingsText.everyProjectRootWasRefused

    #expect(sentence.contains("too wide"))
    #expect(sentence.contains(SettingsText.newRootPrompt))
    #expect(sentence != SettingsText.noProjectsYet)
}

// MARK: - the scanner switches

/// Storage says "always skip"; the switch says "look at this". The mapping between those two
/// meanings is a pair of `!`, and it used to live in the view where no test could reach it.
///
/// Drop or misplace one and every switch inverts: the user turns a scanner **on** and
/// the app writes its identifier into `alwaysSkipScannerIDs`, taking that whole group out of
/// the scan and out of the total, with nothing on screen to say so.
@Test func aScannerSwitchIsOnExactlyWhenTheScannerIsNotSkipped() {
    let row = ScannerRow(id: "flutter.pubCache", title: "Pub cache")
    var draft = Settings.makeDefault(home: "/Users/test")

    #expect(row.isOn(in: draft))

    draft.alwaysSkipScannerIDs = ["flutter.pubCache"]
    #expect(!row.isOn(in: draft))

    // Another scanner's skip must not switch this one off.
    draft.alwaysSkipScannerIDs = ["xcode.archives"]
    #expect(row.isOn(in: draft))
}

@Test func switchingAScannerOffAddsItsIdAndSwitchingItOnRemovesIt() {
    var settings = SettingsModel(
        settings: .makeDefault(home: "/Users/test"), home: "/Users/test")

    settings.setScannerOn("flutter.pubCache", false)
    #expect(settings.draft.alwaysSkipScannerIDs == ["flutter.pubCache"])
    #expect(settings.isDirty)

    settings.setScannerOn("flutter.pubCache", true)
    #expect(settings.draft.alwaysSkipScannerIDs.isEmpty)
}

/// The getter and the setter both invert, so a pair that inverts twice — or not at all —
/// reads back consistently and still writes the opposite of what the user clicked. The
/// assertions on `isSkipped` are what anchor the round trip to the stored meaning.
@Test func theScannerSwitchReadsBackTheStoredMeaningNotJustItsOwnAnswer() {
    let row = ScannerRow(id: "xcode.archives", title: "Xcode archives")
    var settings = SettingsModel(
        settings: .makeDefault(home: "/Users/test"), home: "/Users/test")

    settings.setScannerOn(row.id, false)
    #expect(!row.isOn(in: settings.draft))
    #expect(settings.draft.isSkipped(row.id))

    settings.setScannerOn(row.id, true)
    #expect(row.isOn(in: settings.draft))
    #expect(!settings.draft.isSkipped(row.id))
}
