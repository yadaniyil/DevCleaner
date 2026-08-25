import Testing
import Foundation
@testable import CleanerCore

private let devicesJSON = """
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
 {"udid":"AAA","name":"iPhone 17 Pro Max","state":"Shutdown","isAvailable":true,
  "dataPath":"/sim/AAA/data","dataPathSize":4128636928,"logPath":"/logs/AAA",
  "lastBootedAt":"2026-08-04T19:38:18Z"},
 {"udid":"BBB","name":"iPhone Air","state":"Shutdown","isAvailable":true,
  "dataPath":"/sim/BBB/data","dataPathSize":16408576,"logPath":"/logs/BBB"},
 {"udid":"CCC","name":"iPad Pro","state":"Booted","isAvailable":true,
  "dataPath":"/sim/CCC/data","dataPathSize":2000000000,"logPath":"/logs/CCC",
  "lastBootedAt":"2026-08-09T08:00:00Z"}]}}
"""

// 26.10 is here so the ordering test can tell numeric comparison from string
// comparison. With only 26.5 and 18.2 the two agree, and a plain `>` sort passes.
private let runtimesJSON = """
{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5",
 "version":"26.5","name":"iOS 26.5","buildversion":"23F77","isAvailable":true,
 "bundlePath":"/Library/Developer/CoreSimulator/Volumes/iOS_23F77/…/iOS 26.5.simruntime"},
 {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-10",
 "version":"26.10","name":"iOS 26.10","buildversion":"23G12","isAvailable":true,
 "bundlePath":"/Library/Developer/CoreSimulator/Volumes/iOS_23G12/…/iOS 26.10.simruntime"},
 {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-2",
 "version":"18.2","name":"iOS 18.2","buildversion":"22C150","isAvailable":true,
 "bundlePath":"/Library/Developer/CoreSimulator/Volumes/iOS_22C150/…/iOS 18.2.simruntime"}]}
"""

private func loaderFixture(temp: TempDir) -> DeviceInventoryLoader {
    let runner = FakeProcessRunner(responses: [
        "/usr/bin/xcrun simctl list devices --json":
            ProcessResult(exitCode: 0, stdout: devicesJSON, stderr: ""),
        "/usr/bin/xcrun simctl list runtimes --json":
            ProcessResult(exitCode: 0, stdout: runtimesJSON, stderr: ""),
    ])
    return DeviceInventoryLoader(
        runner: runner, home: temp.path,
        androidSDKPath: temp.path + "/Library/Android/sdk")
}

@Test func parsesSimulatorsIncludingSizeAndLastBooted() throws {
    let temp = TempDir()
    let inventory = loaderFixture(temp: temp).load()
    #expect(inventory.simulators.count == 3)

    let proMax = try #require(inventory.simulators.first { $0.udid == "AAA" })
    #expect(proMax.name == "iPhone 17 Pro Max")
    #expect(proMax.sizeBytes == 4_128_636_928)
    #expect(proMax.isBooted == false)
    // Pin the exact instant, not just non-nil: this decides which simulator is kept,
    // and a constant wrong date survives a non-nil check. 2026-08-04T19:38:18Z.
    #expect(proMax.lastBootedAt == Date(timeIntervalSince1970: 1_785_872_298))

    let air = try #require(inventory.simulators.first { $0.udid == "BBB" })
    #expect(air.lastBootedAt == nil)   // never booted
}

@Test func detectsBootedSimulator() throws {
    let temp = TempDir()
    let inventory = loaderFixture(temp: temp).load()
    #expect(try #require(inventory.simulators.first { $0.udid == "CCC" }).isBooted)
}

@Test func parsesRuntimesAndOrdersNewestFirst() throws {
    let temp = TempDir()
    let inventory = loaderFixture(temp: temp).load()
    // String comparison would give ["26.5", "26.10", "18.2"].
    #expect(inventory.runtimes.map(\.version) == ["26.10", "26.5", "18.2"])
    // `try #require`, never `[0]` on parsed data — standing rule 7. swift-testing has no
    // per-test crash isolation, so an out-of-range trap here would take every other test
    // in the run down with it, and the `#expect` above does not stop execution reaching a
    // subscript.
    let newest = try #require(inventory.runtimes.first)
    #expect(newest.bundlePath.hasSuffix("iOS 26.10.simruntime"))
    let second = try #require(inventory.runtimes.dropFirst().first)
    #expect(second.bundlePath.hasSuffix("iOS 26.5.simruntime"))
}

@Test func versionComparisonIsNumericNotAlphabetic() {
    #expect(DeviceInventoryLoader.isNewer("26.10", than: "26.5"))
    #expect(DeviceInventoryLoader.isNewer("26.5", than: "18.2"))
    #expect(!DeviceInventoryLoader.isNewer("18.2", than: "26.5"))
}

@Test func parsesAVDsWithLastUsedAndSystemImage() throws {
    let temp = TempDir()
    // A stray file in the avd root. Real machines have one: Finder writes .DS_Store
    // whenever it displays ~/.android/avd, and it can easily be the newest thing
    // there. Only an `entry.hasSuffix(".avd")` filter keeps it out of the list; a
    // "not .ini" filter turns it into a phantom emulator that can outrank the real
    // ones by date and be kept while the real ones are deleted.
    temp.makeFile(".android/avd/.DS_Store")

    temp.makeFile(".android/avd/sample_emulator.ini", contents: "path=/whatever\n")
    // The spaced form real config.ini uses: `key = value`, one space either side.
    temp.makeFile(".android/avd/sample_emulator.avd/config.ini",
                  contents: "image.sysdir.1 = system-images/android-34/google_apis/arm64-v8a/\n",
                  modified: Date(timeIntervalSince1970: 1_784_000_000))
    // Records when the AVD was created, not when it last ran.
    temp.makeFile(".android/avd/sample_emulator.avd/userdata-qemu.img",
                  modified: Date(timeIntervalSince1970: 1_785_000_000))
    // The copy-on-write overlay the running emulator actually writes to: newest,
    // so `lastUsed` must be the maximum over the directory entries and not a read
    // of any single pinned filename. Every file here needs an explicit date, or a
    // file created "now" would silently win the maximum.
    temp.makeFile(".android/avd/sample_emulator.avd/userdata-qemu.img.qcow2",
                  modified: Date(timeIntervalSince1970: 1_785_600_000))

    temp.makeFile(".android/avd/sample_avd.ini", contents: "path=/whatever\n")
    // Kept in the unspaced `key=value` form, so both conventions stay covered.
    temp.makeFile(".android/avd/sample_avd.avd/config.ini", contents: "image.sysdir.1=\n")

    let inventory = loaderFixture(temp: temp).load()
    #expect(inventory.avds.map(\.name).sorted() == ["sample_avd", "sample_emulator"])

    let emulator = try #require(inventory.avds.first { $0.name == "sample_emulator" })
    #expect(emulator.lastUsed == Date(timeIntervalSince1970: 1_785_600_000))
    #expect(emulator.systemImageRelativePath == "system-images/android-34/google_apis/arm64-v8a")
    // Feeds deletion, so pin the exact suffix rather than just non-empty. The sibling
    // `.ini` used to be carried here too; `Executor.removeAVDFiles` rebuilds the identical
    // path from the name, so the field was a second copy of one rule and is gone.
    #expect(emulator.directoryPath.hasSuffix("/.android/avd/sample_emulator.avd"))

    let parityFF = try #require(inventory.avds.first { $0.name == "sample_avd" })
    #expect(parityFF.systemImageRelativePath == nil)
    #expect(parityFF.lastUsed != nil)
}

/// Emulators come back in a fixed order, like simulators.
///
/// `contentsOfDirectory` promises no order, so an unsorted list reshuffles between scans
/// and the tick boxes move under the user's cursor — the same reason `loadSimulators` has
/// sorted since it was written, and the same reason `NDKScanner` and `SystemImagesScanner`
/// sort. The names here are deliberately not in the order the directory is built in.
@Test func avdsComeBackSortedByName() {
    let temp = TempDir()
    for name in ["zebra_avd", "Pixel_8_API_34", "sample_emulator"] {
        temp.makeFile(".android/avd/\(name).ini", contents: "path=/whatever\n")
        temp.makeFile(".android/avd/\(name).avd/config.ini", contents: "image.sysdir.1=\n")
    }
    let inventory = loaderFixture(temp: temp).load()
    #expect(inventory.avds.map(\.name) == ["Pixel_8_API_34", "sample_emulator", "zebra_avd"])
}

@Test func missingAVDDirectoryYieldsNoAVDs() {
    let temp = TempDir()
    #expect(loaderFixture(temp: temp).load().avds.isEmpty)
}

@Test func simctlFailureYieldsEmptySimulatorListWithoutCrashing() {
    let temp = TempDir()
    let loader = DeviceInventoryLoader(
        runner: FakeProcessRunner(responses: [:]), home: temp.path,
        androidSDKPath: temp.path + "/sdk")
    let inventory = loader.load()
    #expect(inventory.simulators.isEmpty)
    #expect(inventory.runtimes.isEmpty)
}
