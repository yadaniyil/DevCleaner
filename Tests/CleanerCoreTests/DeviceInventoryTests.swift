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

/// The real document from a machine with two runtimes installed, with the asset hash in
/// the paths replaced. A JSON **object keyed by image UUID** — not an array, which is the
/// shape a reader coming from `simctl list runtimes --json` expects and the reason the
/// parser needs its own test.
///
/// `iOS-18-2` from `runtimesJSON` is deliberately absent: a machine can have a bundle
/// runtime with no image at all, and that runtime must keep the `du` path it always had.
private let runtimeImagesJSON = """
{
  "09A925DA-7B77-461C-B7E8-98E7F377116D" : {
    "build" : "23F77",
    "deletable" : true,
    "identifier" : "09A925DA-7B77-461C-B7E8-98E7F377116D",
    "kind" : "Patchable Cryptex Disk Image",
    "lastUsedAt" : "2026-09-19T18:07:36Z",
    "mountPath" : "/Library/Developer/CoreSimulator/Volumes/iOS_23F77",
    "path" : "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/<hash>.asset/AssetData/Restore/094-56039-099.dmg",
    "platformIdentifier" : "com.apple.platform.iphonesimulator",
    "runtimeBundlePath" : "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime",
    "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    "signatureState" : "Verified",
    "sizeBytes" : 8494282293,
    "state" : "Ready",
    "supportedArchitectures" : ["arm64"],
    "version" : "26.5"
  },
  "78A894D6-CFB8-4758-8F11-5007D28B92EA" : {
    "build" : "23G12",
    "deletable" : true,
    "identifier" : "78A894D6-CFB8-4758-8F11-5007D28B92EA",
    "kind" : "Patchable Cryptex Disk Image",
    "mountPath" : "/Library/Developer/CoreSimulator/Volumes/iOS_23G12",
    "platformIdentifier" : "com.apple.platform.iphonesimulator",
    "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-10",
    "signatureState" : "Unknown",
    "sizeBytes" : 8006076769,
    "state" : "Ready",
    "supportedArchitectures" : ["arm64"],
    "version" : "26.10"
  }
}
"""

private func succeeding(_ stdout: String) -> ProcessResult {
    ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
}

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

/// The same fixture with an answer for `simctl runtime list -j`.
///
/// A separate overload rather than a default argument, so that every test written before
/// disk images existed still runs against a loader whose `runtime list` is **unstubbed** —
/// which is what an older Xcode looks like, and the case that must keep working.
private func loaderFixture(
    temp: TempDir, runtimes: String = runtimesJSON, images: ProcessResult
) -> DeviceInventoryLoader {
    let runner = FakeProcessRunner(responses: [
        "/usr/bin/xcrun simctl list devices --json":
            ProcessResult(exitCode: 0, stdout: devicesJSON, stderr: ""),
        "/usr/bin/xcrun simctl list runtimes --json": succeeding(runtimes),
        "/usr/bin/xcrun simctl runtime list -j": images,
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

// MARK: runtime disk images

/// The document `simctl runtime list -j` really answers, parsed.
///
/// Both facts the app got wrong come out of here. The UUID is what
/// `simctl runtime delete` takes — handed the runtime identifier it deletes nothing — and
/// `sizeBytes` is the image file, which is 8.49 GB where `du` over the mounted bundle said
/// 17.3 GB.
@Test func parsesTheDiskImageBehindEachRuntime() throws {
    let temp = TempDir()
    let inventory = loaderFixture(temp: temp, images: succeeding(runtimeImagesJSON)).load()

    let latest = try #require(inventory.runtimes.first { $0.version == "26.5" })
    let image = try #require(latest.images.first)
    #expect(latest.images.count == 1)
    #expect(image.identifier == "09A925DA-7B77-461C-B7E8-98E7F377116D")
    #expect(image.build == "23F77")
    #expect(image.sizeBytes == 8_494_282_293)
    #expect(image.deletable)
    #expect(image.state == "Ready")
    #expect(latest.imageSizeBytes == 8_494_282_293)
    #expect(latest.everyImageIsDeletable)

    // The second runtime gets its own image and not the first one's.
    let other = try #require(inventory.runtimes.first { $0.version == "26.10" })
    #expect(other.images.map(\.identifier) == ["78A894D6-CFB8-4758-8F11-5007D28B92EA"])

    // And the bundle runtime the document says nothing about keeps the answer it always
    // had: no image, so `du` over `bundlePath` and the runtime identifier to delete with.
    let bundle = try #require(inventory.runtimes.first { $0.version == "18.2" })
    #expect(bundle.images.isEmpty)
    #expect(bundle.imageSizeBytes == nil)
    #expect(bundle.everyImageIsDeletable)
}

/// The build is half of the key, not decoration.
///
/// The runtime identifier is derived from the version, so it cannot tell two builds of one
/// version apart. Matching on it alone would hand this runtime an image of a build it is
/// not, and `simctl runtime delete` would remove several gigabytes the user was never asked
/// about. No match is the safe answer: the runtime falls back to `du` and to the old call.
@Test func aDiskImageOfAnotherBuildIsNotAttachedToThisRuntime() throws {
    let temp = TempDir()
    let installed = """
        {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5",
         "version":"26.5","name":"iOS 26.5","buildversion":"23F77","isAvailable":true,
         "bundlePath":"/rt/26.5.simruntime"}]}
        """
    // The same runtime identifier, a different build.
    let images = """
        {"09A925DA-7B77-461C-B7E8-98E7F377116D":{"build":"23F80","deletable":true,
         "identifier":"09A925DA-7B77-461C-B7E8-98E7F377116D","sizeBytes":8494282293,
         "runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","state":"Ready"}}
        """
    let inventory = loaderFixture(
        temp: temp, runtimes: installed, images: succeeding(images)).load()

    let runtime = try #require(inventory.runtimes.first)
    #expect(runtime.buildVersion == "23F77")
    #expect(runtime.images.isEmpty)
    #expect(runtime.imageSizeBytes == nil)
}

/// Two builds of one version installed side by side stay two runtimes with one image each,
/// and are never merged into one thing holding both images.
///
/// They share a runtime identifier, which is the only key the app had. Merging them would
/// add 16 GB together under one row and then delete both for a click that named one.
@Test func twoBuildsOfOneVersionKeepTheirOwnDiskImages() throws {
    let temp = TempDir()
    let installed = """
        {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5",
         "version":"26.5","name":"iOS 26.5","buildversion":"23F77","isAvailable":true,
         "bundlePath":"/rt/23F77/iOS 26.5.simruntime"},
         {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5",
         "version":"26.5","name":"iOS 26.5","buildversion":"23F80","isAvailable":true,
         "bundlePath":"/rt/23F80/iOS 26.5.simruntime"}]}
        """
    let images = """
        {"AAAAAAAA-0000-0000-0000-000000000001":{"build":"23F77","deletable":true,
         "identifier":"AAAAAAAA-0000-0000-0000-000000000001","sizeBytes":8494282293,
         "runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","state":"Ready"},
         "BBBBBBBB-0000-0000-0000-000000000002":{"build":"23F80","deletable":true,
         "identifier":"BBBBBBBB-0000-0000-0000-000000000002","sizeBytes":8006076769,
         "runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","state":"Ready"}}
        """
    let inventory = loaderFixture(
        temp: temp, runtimes: installed, images: succeeding(images)).load()

    #expect(inventory.runtimes.count == 2)
    let first = try #require(inventory.runtimes.first { $0.buildVersion == "23F77" })
    #expect(first.images.map(\.identifier) == ["AAAAAAAA-0000-0000-0000-000000000001"])
    #expect(first.imageSizeBytes == 8_494_282_293)

    let second = try #require(inventory.runtimes.first { $0.buildVersion == "23F80" })
    #expect(second.images.map(\.identifier) == ["BBBBBBBB-0000-0000-0000-000000000002"])
    #expect(second.imageSizeBytes == 8_006_076_769)
}

/// A runtime whose disk image simctl will not delete says so, and the app has to read it
/// rather than assume it. A row offered over one of these is the bug being fixed.
@Test func aDiskImageTheToolWillNotDeleteIsCarriedAsSuch() throws {
    let temp = TempDir()
    let installed = """
        {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5",
         "version":"26.5","name":"iOS 26.5","buildversion":"23F77","isAvailable":true,
         "bundlePath":"/rt/26.5.simruntime"}]}
        """
    let images = """
        {"09A925DA-7B77-461C-B7E8-98E7F377116D":{"build":"23F77","deletable":false,
         "identifier":"09A925DA-7B77-461C-B7E8-98E7F377116D","sizeBytes":8494282293,
         "runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","state":"Ready"}}
        """
    let inventory = loaderFixture(
        temp: temp, runtimes: installed, images: succeeding(images)).load()

    let runtime = try #require(inventory.runtimes.first)
    #expect(!runtime.everyImageIsDeletable)
    // Still measured. Not being deletable is a reason to hold the row back, never a reason
    // to stop telling the user how much is sitting there.
    #expect(runtime.imageSizeBytes == 8_494_282_293)
}

/// Every way `simctl runtime list -j` can fail to answer, and all of them are ordinary.
///
/// The command is not on every Xcode. Where it is missing — or answers an array, or answers
/// nothing, or exits non-zero — there are no images, and each runtime keeps exactly the
/// behaviour it had before this was read: `du` over the bundle, `simctl runtime delete`
/// with the runtime identifier. A parse that threw, or that decided "no images means no
/// runtimes", would take the whole card away on an older setup.
@Test func anUnreadableRuntimeListLeavesEveryRuntimeExactlyAsItWas() throws {
    let answers = [
        ProcessResult(exitCode: 1, stdout: "", stderr: "Unknown subcommand 'runtime'"),
        ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ProcessResult(exitCode: 0, stdout: "not json at all", stderr: ""),
        // An array rather than the object keyed by UUID: the shape a reader might assume,
        // and the shape a future simctl might answer.
        ProcessResult(exitCode: 0, stdout: "[]", stderr: ""),
        // The object, with nothing in it that names a runtime to attach the image to.
        ProcessResult(exitCode: 0, stdout: #"{"09A925DA":{"sizeBytes":1}}"#, stderr: ""),
        ProcessResult(exitCode: 0, stdout: #"{"09A925DA":"a string, not an object"}"#, stderr: ""),
    ]
    for images in answers {
        let temp = TempDir()
        let inventory = loaderFixture(temp: temp, images: images).load()
        let note = Comment(rawValue: "answering \(images)")

        #expect(inventory.runtimes.count == 3, note)
        #expect(inventory.runtimes.allSatisfy { $0.images.isEmpty }, note)
        #expect(inventory.runtimes.allSatisfy { $0.imageSizeBytes == nil }, note)
        #expect(inventory.runtimes.allSatisfy { $0.everyImageIsDeletable }, note)
        // And the rest of the inventory is untouched by any of it.
        #expect(inventory.simulators.count == 3, note)
        let newest = try #require(inventory.runtimes.first, note)
        #expect(newest.bundlePath.hasSuffix("iOS 26.10.simruntime"), note)
    }
}

/// The two fields the parser fills in for itself, both in the safe direction.
///
/// A document with no `identifier` still has the UUID as its key, so the image is usable
/// rather than dropped. A document with no `deletable` reads as deletable, because that is
/// what this app assumed of every runtime before it asked — the other default would hold
/// back every runtime on any Xcode whose document lacks the key, and the scanner would stop
/// offering the biggest thing it finds on the strength of a missing field.
@Test func aDocumentMissingTheIdentifierUsesItsKeyAndOneMissingDeletableIsDeletable() throws {
    let temp = TempDir()
    let installed = """
        {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5",
         "version":"26.5","name":"iOS 26.5","buildversion":"23F77","isAvailable":true,
         "bundlePath":"/rt/26.5.simruntime"}]}
        """
    let images = """
        {"09A925DA-7B77-461C-B7E8-98E7F377116D":{"build":"23F77","sizeBytes":8494282293,
         "runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5"}}
        """
    let inventory = loaderFixture(
        temp: temp, runtimes: installed, images: succeeding(images)).load()

    let runtime = try #require(inventory.runtimes.first)
    let image = try #require(runtime.images.first)
    #expect(image.identifier == "09A925DA-7B77-461C-B7E8-98E7F377116D")
    #expect(image.deletable)
    #expect(image.state == "")
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
