import Testing
import Foundation
@testable import CleanerCore

@Test func defaultSettingsMatchTheSpec() {
    let settings = Settings.makeDefault(home: "/Users/tester")
    #expect(settings.projectRoots == ["/Users/tester/dev"])
    #expect(settings.activeThresholdDays == 14)
    #expect(settings.deviceRecentUseDays == 7)
    #expect(settings.archiveAgeDays == 30)
    #expect(settings.backgroundScanIntervalHours == 6)
    #expect(settings.pinnedProjectPaths.isEmpty)
    #expect(settings.pinnedSimulatorUDID == nil)
    #expect(settings.pinnedAVDName == nil)
    #expect(settings.alwaysSkipScannerIDs.isEmpty)
    #expect(settings.launchAtLogin == false)
    #expect(settings.menuBarShowsAmount == true)
    #expect(settings.moveToTrash == true)
}

@Test func loadReturnsDefaultsWhenNoFileExists() {
    let temp = TempDir()
    let store = SettingsStore(directory: temp.url, home: "/Users/tester")
    #expect(store.load().activeThresholdDays == 14)
}

@Test func savedSettingsAreReadBack() throws {
    let temp = TempDir()
    let store = SettingsStore(directory: temp.url, home: "/Users/tester")
    var settings = store.load()
    settings.activeThresholdDays = 30
    settings.pinnedProjectPaths = ["/Users/tester/dev/sample-project"]
    settings.alwaysSkipScannerIDs = ["flutter.pubCache"]
    try store.save(settings)

    let reloaded = SettingsStore(directory: temp.url, home: "/Users/tester").load()
    #expect(reloaded.activeThresholdDays == 30)
    #expect(reloaded.pinnedProjectPaths == ["/Users/tester/dev/sample-project"])
    #expect(reloaded.alwaysSkipScannerIDs == ["flutter.pubCache"])
    // The net underneath the three named fields: every one of the 12 must survive
    // the round trip. Without this, a save/load defect that loses or forces any
    // other field — moveToTrash above all — passes the whole suite unnoticed.
    #expect(reloaded == settings)
}

@Test func saveCreatesTheDirectoryWhenItDoesNotExistYet() throws {
    let temp = TempDir()
    let nested = temp.url.appendingPathComponent("DevCleaner", isDirectory: true)
    let store = SettingsStore(directory: nested, home: "/Users/tester")
    var settings = store.load()
    settings.activeThresholdDays = 7
    try store.save(settings)

    #expect(SettingsStore(directory: nested, home: "/Users/tester").load().activeThresholdDays == 7)
}

@Test func corruptFileFallsBackToDefaultsInsteadOfCrashing() throws {
    let temp = TempDir()
    temp.makeFile("settings.json", contents: "{ this is not json")
    let store = SettingsStore(directory: temp.url, home: "/Users/tester")
    #expect(store.load().activeThresholdDays == 14)
}

@Test func unknownFieldsInFileDoNotBreakLoading() throws {
    let temp = TempDir()
    temp.makeFile("settings.json", contents: """
    {"projectRoots":["/Users/tester/dev"],"activeThresholdDays":21,\
    "deviceRecentUseDays":7,\
    "pinnedProjectPaths":[],"alwaysSkipScannerIDs":[],"archiveAgeDays":30,\
    "backgroundScanIntervalHours":6,"launchAtLogin":false,\
    "menuBarShowsAmount":true,"moveToTrash":true,\
    "somethingFromAFutureVersion":42}
    """)
    let store = SettingsStore(directory: temp.url, home: "/Users/tester")
    #expect(store.load().activeThresholdDays == 21)
}

/// A settings file written before `deviceRecentUseDays` existed — that is, by every
/// build up to the previous commit. Synthesised decoding fails such a file with
/// `keyNotFound`, `load()` swallows that with `try?`, and the user silently loses
/// every setting in it. `pinnedSimulatorUDID` is the one that costs data: it is the
/// only thing keeping a simulator off a permanent `simctl delete`.
@Test func aSettingsFileMissingTheNewestFieldStillKeepsItsPins() throws {
    let temp = TempDir()
    temp.makeFile("settings.json", contents: """
    {"projectRoots":["/Users/tester/work"],"activeThresholdDays":21,\
    "pinnedProjectPaths":["/Users/tester/work/sample-project"],\
    "pinnedSimulatorUDID":"7F1C-AAAA","pinnedAVDName":"Pixel_9_API_35",\
    "alwaysSkipScannerIDs":["flutter.pubCache"],"archiveAgeDays":45,\
    "backgroundScanIntervalHours":12,"launchAtLogin":true,\
    "menuBarShowsAmount":false,"moveToTrash":false}
    """)
    let settings = SettingsStore(directory: temp.url, home: "/Users/tester").load()

    #expect(settings.pinnedSimulatorUDID == "7F1C-AAAA")
    #expect(settings.pinnedAVDName == "Pixel_9_API_35")
    #expect(settings.pinnedProjectPaths == ["/Users/tester/work/sample-project"])
    #expect(settings.alwaysSkipScannerIDs == ["flutter.pubCache"])
    #expect(settings.moveToTrash == false)
    #expect(settings.projectRoots == ["/Users/tester/work"])
    #expect(settings.activeThresholdDays == 21)
    // The one key the file predates takes its default, and nothing else moves.
    #expect(settings.deviceRecentUseDays == 7)
}

/// The general shape, so the next field added cannot repeat the bug above: a file
/// with no keys at all decodes to exactly the defaults instead of throwing. Any
/// future field decoded without a fallback fails this test the moment it is added.
///
/// Deliberately goes through `JSONDecoder` and not through `load()`. `load()` answers
/// defaults for a file it fails to decode as well as for a file it decodes to
/// defaults, so the two are indistinguishable from there and the assertion would hold
/// either way. Here a throw is a failure.
@Test func aSettingsFileWithNoKeysAtAllDecodesToTheDefaultsInsteadOfThrowing() throws {
    let decoder = JSONDecoder()
    decoder.userInfo[.settingsHome] = "/Users/tester"
    let data = try #require("{}".data(using: .utf8))

    let settings = try decoder.decode(Settings.self, from: data)

    #expect(settings == .makeDefault(home: "/Users/tester"))
    // Proves the home reached the decoder. `projectRoots` is the one field whose
    // default cannot be written as a constant.
    #expect(settings.projectRoots == ["/Users/tester/dev"])
}

// MARK: - tilde expansion

/// The whole rule, one row per shape, so an expansion that fires too eagerly is caught by
/// the same test as one that never fires at all.
///
/// The home is `/Users/tester` and the roots live under it, so an expanded value and an
/// unexpanded one are never the same string: `~/dev` and `/Users/tester/dev` cannot be
/// confused for each other in a failure message, and neither can be confused with a real
/// machine's `/Users/<someone>/dev`.
@Test func onlyALeadingTildeSlashIsExpanded() {
    let home = "/Users/tester"
    let cases: [(input: String, expected: String)] = [
        // The case the whole fix exists for.
        ("~/dev", "/Users/tester/dev"),
        ("~/dev/sample-project", "/Users/tester/dev/sample-project"),
        // The `~/…` form with nothing after the slash. It is the home directory, and
        // `isTooWideForAProjectRoot` refuses it for being exactly that.
        ("~/", "/Users/tester"),
        // Left alone: refused later for not being absolute, and quoted back as typed.
        ("~", "~"),
        // Another user's home. No injected home can say where it is, and asking the real
        // machine's password database is the dependency the injected home exists to avoid.
        ("~someoneelse/dev", "~someoneelse/dev"),
        ("~root", "~root"),
        // A tilde that is part of an ordinary directory name, not a home reference. An
        // over-eager rule that expanded any tilde would mangle both of these.
        ("/tmp/~foo", "/tmp/~foo"),
        ("/Users/tester/a~b", "/Users/tester/a~b"),
        ("/Users/tester/~/dev", "/Users/tester/~/dev"),
        // Already absolute, and a home other than the injected one: untouched either way.
        ("/Users/tester/dev", "/Users/tester/dev"),
        ("/Users/someoneelse/dev", "/Users/someoneelse/dev"),
        // Relative. Refused later for the same reason `~` is.
        ("dev", "dev"),
        ("./dev", "./dev"),
        ("", ""),
    ]
    for (input, expected) in cases {
        #expect(TildePath.expanded(input, home: home) == expected, "input was \"\(input)\"")
    }
}

/// The defect this branch fixes, at the boundary that had it: a hand-edited `settings.json`
/// naming `~/dev` used to load as the four characters `~/dev`, which
/// `contentsOfDirectory(atPath:)` and `realpath` both fail to find, so the root discovered
/// nothing and guarded nothing and said nothing about either.
@Test func aHandEditedTildeRootIsExpandedOnTheWayIn() {
    let temp = TempDir()
    temp.makeFile("settings.json", contents: #"""
    {"projectRoots":["~/dev","~/work"],"pinnedProjectPaths":["~/dev/sample-project"]}
    """#)

    let settings = SettingsStore(directory: temp.url, home: "/Users/tester").load()

    #expect(settings.projectRoots == ["/Users/tester/dev", "/Users/tester/work"])
    // The second path-shaped field. A pin that matches no project is a project left
    // unprotected, and its build output is then offered for deletion.
    #expect(settings.pinnedProjectPaths == ["/Users/tester/dev/sample-project"])
}

/// The home is the injected one, not the process's. Two stores over the **same file** give
/// two different answers, which no constant and no `NSHomeDirectory()` can do.
@Test func theTildeIsExpandedAgainstTheInjectedHome() {
    let temp = TempDir()
    temp.makeFile("settings.json", contents: #"{"projectRoots":["~/dev"]}"#)

    #expect(SettingsStore(directory: temp.url, home: "/Users/one").load()
        .projectRoots == ["/Users/one/dev"])
    #expect(SettingsStore(directory: temp.url, home: "/Users/two").load()
        .projectRoots == ["/Users/two/dev"])
}

/// Loading expands; it does not write. The file the user typed still says what they typed
/// until they save from the settings window, and only then is it rewritten expanded.
@Test func loadingLeavesTheFileExactlyAsTheUserWroteIt() throws {
    let temp = TempDir()
    let file = temp.makeFile("settings.json", contents: #"{"projectRoots":["~/dev"]}"#)
    let store = SettingsStore(directory: temp.url, home: "/Users/tester")

    #expect(store.load().projectRoots == ["/Users/tester/dev"])
    let onDisk = try String(contentsOfFile: file, encoding: .utf8)
    #expect(onDisk == #"{"projectRoots":["~/dev"]}"#)

    // And a save writes the expanded form, because the expanded form is what was loaded.
    // Read back through a *different* home: a file still holding `~/dev` would answer
    // `/Users/other/dev` here, so this says the tilde is really gone from the file.
    try store.save(store.load())
    #expect(SettingsStore(directory: temp.url, home: "/Users/other").load()
        .projectRoots == ["/Users/tester/dev"])
}

/// The width check measures the directory a root **names**, not the characters it is
/// written with. Measured as typed, `~/dev` is not an absolute path, so every root a user
/// writes by hand would be refused with a sentence recommending `~/dev`.
@Test func theWidthCheckMeasuresTheRootAfterExpansionNotAsTyped() throws {
    let temp = TempDir()
    temp.makeDirectory("dev")
    let store = SettingsStore(directory: temp.url, home: temp.path)
    var settings = Settings.makeDefault(home: temp.path)

    settings.projectRoots = ["~/dev"]
    try store.save(settings)
    #expect(store.load().projectRoots == [temp.path + "/dev"])

    // The same rule refusing, also on what the expansion produced: `~/` is the home
    // directory, and the sentence still quotes the two characters the user wrote.
    settings.projectRoots = ["~/"]
    #expect(throws: SettingsError.projectRootTooWide("~/")) { try store.save(settings) }
}

/// A bare `~` reaches the engine unchanged and is still refused — as a value that is not
/// absolute rather than as the home directory. The sentence the user reads quotes the one
/// character they actually typed.
@Test func aBareTildeIsNotExpandedAndIsStillRefusedAsAProjectRoot() throws {
    let temp = TempDir()
    temp.makeFile("settings.json", contents: #"{"projectRoots":["~"]}"#)
    let store = SettingsStore(directory: temp.url, home: "/Users/tester")

    let loaded = store.load()
    #expect(loaded.projectRoots == ["~"])
    #expect(throws: SettingsError.projectRootTooWide("~")) { try store.save(loaded) }
}

/// The over-fix guard for the file boundary. Absolute paths, and paths whose tilde is not a
/// home reference, come back byte for byte as they were stored — including a pin, which is
/// matched against a discovered project as text and breaks if anything touches it.
@Test func loadLeavesEveryPathThatIsAlreadyAbsoluteAlone() {
    let temp = TempDir()
    temp.makeFile("settings.json", contents: """
    {"projectRoots":["/Users/tester/dev","/tmp/~foo","/Users/other/code"],\
    "pinnedProjectPaths":["/Users/tester/dev/a~b"],\
    "pinnedSimulatorUDID":"7F1C-AAAA","pinnedAVDName":"Pixel_9_API_35",\
    "alwaysSkipScannerIDs":["flutter.pubCache"]}
    """)

    let settings = SettingsStore(directory: temp.url, home: "/Users/tester").load()

    #expect(settings.projectRoots == ["/Users/tester/dev", "/tmp/~foo", "/Users/other/code"])
    #expect(settings.pinnedProjectPaths == ["/Users/tester/dev/a~b"])
    // The fields that are not paths. A `~` in any of them is a character of a name.
    #expect(settings.pinnedSimulatorUDID == "7F1C-AAAA")
    #expect(settings.pinnedAVDName == "Pixel_9_API_35")
    #expect(settings.alwaysSkipScannerIDs == ["flutter.pubCache"])
}

/// The over-fix guard for the fields that are **not** paths. A settings file is
/// hand-editable text, so a value that looks like a path can end up in any of them, and
/// their meaning is their spelling: an unrecognised scanner identifier is kept exactly as
/// written on purpose — see `SettingsModel.setSkipped` — and a UDID or an AVD name expanded
/// into a directory matches no device, so the pin keeping that device off a permanent
/// `simctl delete` stops working. "Expand every string" would do all three.
@Test func loadExpandsThePathFieldsAndNothingElse() {
    let temp = TempDir()
    temp.makeFile("settings.json", contents: """
    {"projectRoots":["~/dev"],\
    "alwaysSkipScannerIDs":["flutter.pubCache","~/not-a-scanner"],\
    "pinnedSimulatorUDID":"~/not-a-udid","pinnedAVDName":"~/not-an-avd"}
    """)

    let settings = SettingsStore(directory: temp.url, home: "/Users/tester").load()

    // The path field moved.
    #expect(settings.projectRoots == ["/Users/tester/dev"])
    // Nothing else did.
    #expect(settings.alwaysSkipScannerIDs == ["flutter.pubCache", "~/not-a-scanner"])
    #expect(settings.pinnedSimulatorUDID == "~/not-a-udid")
    #expect(settings.pinnedAVDName == "~/not-an-avd")
}

@Test func skippedScannerCheckIsCaseSensitiveAndExact() {
    var settings = Settings.makeDefault(home: "/Users/tester")
    settings.alwaysSkipScannerIDs = ["flutter.pubCache"]
    #expect(settings.isSkipped("flutter.pubCache"))
    #expect(!settings.isSkipped("flutter.fvm"))
}
