import Testing
import Foundation
@testable import CleanerCore

private let now = Date(timeIntervalSince1970: 1_786_000_000)

private func device(_ udid: String, name: String, size: Int64, booted: Date?,
                    runtime: String = "iOS-26-5", isBooted: Bool = false) -> SimulatorDevice {
    SimulatorDevice(
        udid: udid, name: name, runtimeIdentifier: runtime, isBooted: isBooted,
        sizeBytes: size, lastBootedAt: booted)
}

private func context(devices: DeviceInventory, protection: ProtectionSet,
                     temp: TempDir, sizes: [String: Int64] = [:],
                     sizeMeasurer: (any SizeMeasuring)? = nil) -> ScanContext {
    ScanContext(
        settings: .makeDefault(home: temp.path), protection: protection, projects: [],
        devices: devices, home: temp.path, androidSDKPath: temp.path + "/sdk",
        sizeMeasurer: sizeMeasurer ?? FixedSizeMeasurer(sizes),
        runner: FakeProcessRunner(responses: [:]),
        fileManager: .default, now: now)
}

/// The memberwise initialiser has eight arguments and no defaults. `protected`
/// defaults to the kept device alone, labelled the way `ProtectionResolver` labels it
/// when no other device is recent or close enough to also survive.
private func protection(keptSimulator: String?,
                        protected: [String: ProtectionReason]? = nil,
                        runtimes: [String: ProtectionReason] = [:]) -> ProtectionSet {
    ProtectionSet(
        projects: [:], keptSimulatorUDID: keptSimulator, keptAVDName: nil,
        protectedSimulatorUDIDs: protected
            ?? keptSimulator.map { [$0: .mostRecentlyUsedDevice] } ?? [:],
        protectedAVDNames: [:],
        flutterVersions: [:], gradleDistributions: [:], runtimeIdentifiers: runtimes)
}

// MARK: devices

@Test func offersEverySimulatorExceptTheKeptOne() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [
        device("AAA", name: "iPhone 17 Pro Max", size: 4_128_636_928, booted: now.addingTimeInterval(-86_400 * 5)),
        device("BBB", name: "iPhone Air", size: 16_408_576, booted: nil),
        device("CCC", name: "iPad Pro", size: 2_000_000_000, booted: now),
    ], runtimes: [], avds: [])

    let items = await SimulatorDevicesScanner()
        .scan(context(devices: devices, protection: protection(keptSimulator: "CCC"), temp: temp))

    #expect(items.count == 3)
    let kept = try #require(items.first { $0.name.contains("iPad Pro") })
    #expect(kept.protection == .mostRecentlyUsedDevice)
    #expect(kept.detail == "the simulator you keep")
    #expect(items.filter(\.isDeletable).count == 2)
    #expect(items.filter(\.isDeletable).reduce(0) { $0 + $1.sizeBytes } == 4_145_045_504)
}

/// The two facts about a device row that were both wrong.
///
/// `risk` was `.safe` — "regenerated automatically by a normal build" — on the only rows
/// in the app that cannot be undone at all, so `ReportText.mark` printed a 12.9 GB
/// permanent simulator deletion with the same `x` as a Gradle transform cache while an
/// 84 MB archive bound for the Trash got the warning `!`. And an offered device carried no
/// detail whatsoever, unlike all fourteen other scanners, so `sample_emulator_1` showed as a
/// bare `[x] 9.2 GB` with nothing to read.
@Test func anOfferedSimulatorIsMarkedElevatedAndSaysWhatDeletingItCosts() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [
        device("AAA", name: "iPhone 17 Pro Max", size: 12_860_000_000,
               booted: now.addingTimeInterval(-86_400 * 30)),
        device("CCC", name: "iPad Pro", size: 2_000_000_000, booted: now),
    ], runtimes: [], avds: [])

    let items = await SimulatorDevicesScanner()
        .scan(context(devices: devices, protection: protection(keptSimulator: "CCC"), temp: temp))

    let offered = try #require(items.first { $0.name == "iPhone 17 Pro Max" })
    #expect(offered.isDeletable)
    #expect(offered.risk == .elevated)
    #expect(ReportText.mark(for: offered) == "!")
    let detail = try #require(offered.detail)
    #expect(detail == SimulatorDevicesScanner.offeredDetail)
    #expect(detail.contains("no Trash and no undo"))

    // The kept row is `.elevated` too — the risk of the row is about the thing, not about
    // whether it happens to be ticked today — and its mark stays `-` because it is kept.
    let kept = try #require(items.first { $0.name == "iPad Pro" })
    #expect(kept.risk == .elevated)
    #expect(ReportText.mark(for: kept) == "-")
}

/// The scanner half of the booted-simulator fix. The resolver supplies the reason; this
/// pins that the row is not deletable and says why in the user's words rather than
/// falling through to a catch-all.
@Test func aSimulatorRunningNowIsShownAsKeptAndSaysItIsRunning() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [
        device("RUNNING", name: "Sample Design Simulator", size: 7_090_000_000,
               booted: now.addingTimeInterval(-86_400 * 9), isBooted: true),
        device("CCC", name: "iPad Pro", size: 2_000_000_000, booted: now),
    ], runtimes: [], avds: [])

    let items = await SimulatorDevicesScanner().scan(context(
        devices: devices,
        protection: protection(
            keptSimulator: "CCC",
            protected: ["CCC": .mostRecentlyUsedDevice, "RUNNING": .bootedDevice]),
        temp: temp))

    let running = try #require(items.first { $0.name == "Sample Design Simulator" })
    #expect(running.protection == .bootedDevice)
    #expect(!running.isDeletable)
    #expect(running.detail == "running right now")
    #expect(ReportText.mark(for: running) == "-")
}

/// The ordering of the `switch` that picks the row's words, not just its contents.
///
/// The device that is running is very often also the newest, and therefore the one
/// labelled as kept. `case _ where device.udid == kept` sits below `.bootedDevice` on
/// purpose: above it, the row would read "the simulator you keep" and the one fact the
/// user needs — that this is the session they are working in — would never be shown.
@Test func aRunningSimulatorThatIsAlsoTheKeptOneStillSaysItIsRunning() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [
        device("RUNNING", name: "Sample Design Simulator", size: 7_090_000_000,
               booted: now, isBooted: true),
    ], runtimes: [], avds: [])

    let items = await SimulatorDevicesScanner().scan(context(
        devices: devices,
        protection: protection(keptSimulator: "RUNNING",
                               protected: ["RUNNING": .bootedDevice]),
        temp: temp))

    let running = try #require(items.first)
    #expect(running.detail == "running right now")
    #expect(running.detail != "the simulator you keep")
}

/// A runtime whose bundle `du` could not measure is shown, not hidden, and not ticked.
/// The measurer leaves such a path out of its dictionary; reported as 0 it would have been
/// ticked with its real size unknown — and the only runtime on a real dev machine sits on a
/// separate volume and is 17 GB.
@Test func aRuntimeThatCouldNotBeMeasuredIsOfferedButNotTicked() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                         buildVersion: "22C150", bundlePath: "/Volumes/Other/rt/18.2"),
        SimulatorRuntime(identifier: "iOS-17-0", name: "iOS 17.0", version: "17.0",
                         buildVersion: "21A328", bundlePath: "/rt/17.0"),
    ], avds: [])

    // `/Volumes/Other/rt/18.2` is absent from the measurer's answer: could not measure.
    // `/rt/17.0` measured, and measured as a real number.
    let items = await SimulatorRuntimesScanner().scan(context(
        devices: devices, protection: protection(keptSimulator: nil), temp: temp,
        sizeMeasurer: PartialSizeMeasurer(["/rt/17.0": 7_000_000_000])))

    let unmeasured = try #require(items.first { $0.name == "iOS 18.2" })
    #expect(unmeasured.isDeletable)
    #expect(unmeasured.startsUnticked)
    #expect(!unmeasured.selectedByDefault)
    #expect(ReportText.mark(for: unmeasured) == " ")

    // The over-fix guard: the runtime that *was* measured is still ticked.
    let measured = try #require(items.first { $0.name == "iOS 17.0" })
    #expect(measured.selectedByDefault)
    #expect(!measured.startsUnticked)
    #expect(measured.sizeBytes == 7_000_000_000)
}

@Test func simulatorItemsUseTheDeleteSimulatorMethod() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(
        simulators: [device("AAA", name: "iPhone Air", size: 10, booted: nil)],
        runtimes: [], avds: [])
    let items = await SimulatorDevicesScanner()
        .scan(context(devices: devices, protection: protection(keptSimulator: nil), temp: temp))
    let item = try #require(items.first)
    #expect(item.method == .deleteSimulator(udid: "AAA"))
    #expect(item.id == "ios.simulators|AAA")
}

@Test func neverBootedSimulatorSaysSoInItsDetail() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(
        simulators: [device("BBB", name: "iPhone Air", size: 16_408_576, booted: nil)],
        runtimes: [], avds: [])
    let items = await SimulatorDevicesScanner()
        .scan(context(devices: devices, protection: protection(keptSimulator: nil), temp: temp))
    let item = try #require(items.first)
    #expect(item.detail == "never booted · " + SimulatorDevicesScanner.offeredDetail)
    #expect(item.lastUsed == nil)
}

/// `simctl` reports `dataPathSize` for every device, so measuring the data paths
/// with `du` would walk tens of gigabytes for numbers already in hand. Nothing in
/// the returned items shows whether that happened, so it needs its own assertion.
@Test func devicesScannerNeverMeasuresAnything() async {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [
        device("AAA", name: "iPhone Air", size: 10, booted: nil),
        device("BBB", name: "iPad Pro", size: 20, booted: now),
    ], runtimes: [], avds: [])
    let measurer = CallCountingSizeMeasurer()

    let items = await SimulatorDevicesScanner().scan(context(
        devices: devices, protection: protection(keptSimulator: nil),
        temp: temp, sizeMeasurer: measurer))

    #expect(items.count == 2)
    let callCount = await measurer.callCount
    #expect(callCount == 0)
}

/// A simulator cannot be moved to the Trash — `simctl delete` is permanent. When
/// two devices were last used within two seconds of each other the app cannot tell
/// which one the user actually works with, so `ProtectionResolver` puts both in
/// `protectedSimulatorUDIDs` and every one of them must be kept. Reading only
/// `keptSimulatorUDID` makes that guard inert.
@Test func everySimulatorTheAppCannotTellApartIsProtected() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [
        device("AAA", name: "iPhone 17 Pro", size: 3_000_000_000, booted: now.addingTimeInterval(-1)),
        device("BBB", name: "iPhone Air", size: 2_000_000_000, booted: now),
        device("CCC", name: "iPad Pro", size: 1_000_000_000, booted: now.addingTimeInterval(-86_400 * 5)),
    ], runtimes: [], avds: [])

    let items = await SimulatorDevicesScanner().scan(context(
        devices: devices,
        protection: protection(keptSimulator: "BBB", protected: [
            "BBB": .mostRecentlyUsedDevice, "AAA": .mostRecentlyUsedDevice,
        ]),
        temp: temp))

    #expect(items.count == 3)
    let winner = try #require(items.first { $0.name == "iPhone Air" })
    #expect(!winner.isDeletable)
    #expect(winner.protection == .mostRecentlyUsedDevice)
    #expect(winner.detail == "the simulator you keep")

    let twin = try #require(items.first { $0.name == "iPhone 17 Pro" })
    #expect(!twin.isDeletable)
    #expect(twin.protection == .mostRecentlyUsedDevice)
    #expect(twin.detail == "most recently used")

    let offered = try #require(items.first { $0.name == "iPad Pro" })
    #expect(offered.isDeletable)
    #expect(offered.protection == nil)
    #expect(offered.method == .deleteSimulator(udid: "CCC"))
}

/// The same three devices through the real `ProtectionResolver`, so the two halves
/// of the guard are pinned together rather than only against a hand-built set.
///
/// **Every** device here is older than `deviceRecentUseDays`, which is the only regime
/// where the two-second tie rule decides anything. A pair dated `now` and `now − 1s`
/// is protected by the 7-day rule whatever the tie rule does, so the test would pass
/// with the tie branch deleted.
@Test func resolverAndScannerTogetherKeepTwoDevicesOneSecondApart() async throws {
    let temp = TempDir()
    let old = now.addingTimeInterval(-86_400 * 30)
    let devices = DeviceInventory(simulators: [
        device("AAA", name: "iPhone 17 Pro", size: 3_000_000_000, booted: old.addingTimeInterval(-1)),
        device("BBB", name: "iPhone Air", size: 2_000_000_000, booted: old),
        device("CCC", name: "iPad Pro", size: 1_000_000_000, booted: now.addingTimeInterval(-86_400 * 60)),
    ], runtimes: [], avds: [])
    let resolved = ProtectionResolver(settings: .makeDefault(home: temp.path))
        .resolve(projects: [], activity: [:], devices: devices, now: now)

    let items = await SimulatorDevicesScanner()
        .scan(context(devices: devices, protection: resolved, temp: temp))

    #expect(items.filter(\.isDeletable).count == 1)
    let offered = try #require(items.first { $0.isDeletable })
    #expect(offered.name == "iPad Pro")
    // The device the tie rule alone saves. Nothing else in this fixture protects it.
    let twin = try #require(items.first { $0.name == "iPhone 17 Pro" })
    #expect(twin.protection == .mostRecentlyUsedDevice)
}

/// The other side of the same boundary. The window is two seconds exclusive, so
/// devices exactly two seconds apart are distinguishable and only the newest is
/// kept — otherwise every device on the machine could end up protected.
///
/// Both devices are 30 days old so that the window is the only rule in play. Fresh
/// timestamps would protect both through `deviceRecentUseDays` no matter what the
/// window did.
@Test func devicesExactlyTwoSecondsApartAreTellableApartSoOnlyTheNewestIsKept() async throws {
    let temp = TempDir()
    let old = now.addingTimeInterval(-86_400 * 30)
    let devices = DeviceInventory(simulators: [
        device("AAA", name: "iPhone 17 Pro", size: 3_000_000_000, booted: old.addingTimeInterval(-2)),
        device("BBB", name: "iPhone Air", size: 2_000_000_000, booted: old),
    ], runtimes: [], avds: [])
    let resolved = ProtectionResolver(settings: .makeDefault(home: temp.path))
        .resolve(projects: [], activity: [:], devices: devices, now: now)

    let items = await SimulatorDevicesScanner()
        .scan(context(devices: devices, protection: resolved, temp: temp))

    #expect(items.filter(\.isDeletable).count == 1)
    let offered = try #require(items.first { $0.isDeletable })
    #expect(offered.name == "iPhone 17 Pro")
    let kept = try #require(items.first { $0.name == "iPhone Air" })
    #expect(kept.protection == .mostRecentlyUsedDevice)
}

/// The rule the user chose: every device used in the last `deviceRecentUseDays` is
/// kept, not only the newest. On a real dev machine this is the difference between
/// offering a 12.86 GB simulator booted 27 hours ago and leaving it alone. A scanner
/// that reads only `keptSimulatorUDID` puts it back on the list.
@Test func recentlyUsedSimulatorsAreProtectedNotOnlyTheNewest() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [
        device("AAA", name: "iPhone 17", size: 12_860_000_000, booted: now.addingTimeInterval(-86_400 * 3)),
        device("BBB", name: "Sample Design Simulator", size: 7_090_000_000, booted: now),
        device("CCC", name: "sample-ios-simulator", size: 3_690_000_000, booted: now.addingTimeInterval(-86_400 * 30)),
    ], runtimes: [], avds: [])

    let items = await SimulatorDevicesScanner().scan(context(
        devices: devices,
        protection: protection(keptSimulator: "BBB", protected: [
            "BBB": .mostRecentlyUsedDevice, "AAA": .recentlyUsedDevice(days: 7),
        ]),
        temp: temp))

    let recent = try #require(items.first { $0.name == "iPhone 17" })
    #expect(!recent.isDeletable)
    #expect(recent.protection == .recentlyUsedDevice(days: 7))
    #expect(recent.detail == "used in the last 7 days")

    let winner = try #require(items.first { $0.name == "Sample Design Simulator" })
    #expect(winner.protection == .mostRecentlyUsedDevice)
    #expect(winner.detail == "the simulator you keep")

    #expect(items.filter(\.isDeletable).map(\.name) == ["sample-ios-simulator"])
}

/// A pinned device says so. Before `protectedSimulatorUDIDs` carried a reason the
/// scanner could not tell "kept because it is newest" from "kept because you pinned
/// it", and showed "most recently used" on a device that may be months old.
///
/// The second device matters as much as the pinned one. It is the newest simulator
/// on the machine, protected but not kept, and a catch-all branch labelled it "used
/// at the same moment as the one you keep" — a device booted today described as
/// sharing a moment with one booted 90 days ago.
@Test func pinnedSimulatorSaysItIsPinnedRatherThanMostRecentlyUsed() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [
        device("AAA", name: "iPhone 17", size: 100, booted: now.addingTimeInterval(-86_400 * 90)),
        device("BBB", name: "iPad Pro", size: 200, booted: now),
    ], runtimes: [], avds: [])

    let items = await SimulatorDevicesScanner().scan(context(
        devices: devices,
        protection: protection(keptSimulator: "AAA", protected: [
            "AAA": .pinnedDevice, "BBB": .mostRecentlyUsedDevice,
        ]),
        temp: temp))

    let pinned = try #require(items.first { $0.name == "iPhone 17" })
    #expect(pinned.protection == .pinnedDevice)
    #expect(pinned.detail == "pinned in settings")

    let newest = try #require(items.first { $0.name == "iPad Pro" })
    #expect(newest.protection == .mostRecentlyUsedDevice)
    #expect(newest.detail == "most recently used")

    #expect(items.filter(\.isDeletable).isEmpty)
}

// MARK: runtimes

@Test func protectedRuntimesAreShownButNotOffered() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
                         buildVersion: "23F77", bundlePath: "/rt/26.5"),
        SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                         buildVersion: "22C150", bundlePath: "/rt/18.2"),
    ], avds: [])

    let items = await SimulatorRuntimesScanner().scan(context(
        devices: devices,
        protection: protection(keptSimulator: nil, runtimes: ["iOS-26-5": .newestRuntime]),
        temp: temp, sizes: ["/rt/26.5": 16_000_000_000, "/rt/18.2": 7_000_000_000]))

    #expect(items.count == 2)
    let newest = try #require(items.first { $0.name == "iOS 26.5" })
    #expect(newest.protection == .newestRuntime)
    #expect(!newest.isDeletable)
    // A kept row says why it is kept. It used to carry "removed permanently;
    // re-downloaded from Apple, several gigabytes" — a promise about a button this row
    // does not have — which is the same kind of untruth as a card offering to delete a
    // runtime the tool will refuse.
    #expect(newest.detail == "build 23F77 · newest installed runtime")

    let old = try #require(items.first { $0.name == "iOS 18.2" })
    #expect(old.isDeletable)
    #expect(old.sizeBytes == 7_000_000_000)
    #expect(old.detail == "build 22C150 · " + SimulatorRuntimesScanner.offeredDetail)
    #expect(old.method == .deleteSimulatorRuntime(identifier: "iOS-18-2"))
    #expect(old.id == "ios.runtimes|iOS-18-2")
}

/// The risk half of `anOfferedSimulatorIsMarkedElevatedAndSaysWhatDeletingItCosts`
/// above and `anOfferedAVDIsMarkedElevatedAndSaysWhatDeletingItCosts`
/// (`AndroidScannerTests.swift:85`). `simctl runtime delete` is exactly as permanent
/// as deleting the device or the emulator itself, so `ReportText.mark` must print the
/// warning `!` here too, not the plain `x` a `.safe` row gets.
@Test func anOfferedRuntimeIsMarkedElevatedBecauseItCannotBeUndone() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                         buildVersion: "22C150", bundlePath: "/rt/18.2"),
    ], avds: [])

    let items = await SimulatorRuntimesScanner().scan(context(
        devices: devices, protection: protection(keptSimulator: nil), temp: temp,
        sizes: ["/rt/18.2": 7_000_000_000]))

    let offered = try #require(items.first)
    #expect(offered.isDeletable)
    #expect(offered.risk == .elevated)
    #expect(ReportText.mark(for: offered) == "!")
}

@Test func runtimeWithoutBundlePathIsSkippedBecauseItCannotBeMeasured() async {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                         buildVersion: "22C150", bundlePath: ""),
    ], avds: [])
    let items = await SimulatorRuntimesScanner()
        .scan(context(devices: devices, protection: protection(keptSimulator: nil), temp: temp))
    #expect(items.isEmpty)
}

/// A fixture where every runtime lacks a bundle path cannot show that the ones
/// with a path survive. An unmeasurable runtime shown at zero bytes would invite
/// the user to delete sixteen gigabytes believing it frees nothing.
@Test func onlyTheRuntimeWithoutABundlePathIsDropped() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
                         buildVersion: "23F77", bundlePath: "/rt/26.5"),
        SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                         buildVersion: "22C150", bundlePath: ""),
    ], avds: [])

    let items = await SimulatorRuntimesScanner().scan(context(
        devices: devices, protection: protection(keptSimulator: nil), temp: temp,
        sizes: ["/rt/26.5": 16_000_000_000]))

    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.name == "iOS 26.5")
    #expect(item.sizeBytes == 16_000_000_000)
}

// MARK: runtimes with a disk image

private func image(_ identifier: String, build: String, bytes: Int64,
                   deletable: Bool = true) -> SimulatorRuntimeImage {
    SimulatorRuntimeImage(identifier: identifier, build: build, sizeBytes: bytes,
                          deletable: deletable, state: "Ready")
}

/// **The card said 17.3 GB and the image on disk is 8.49 GB.**
///
/// `bundlePath` is inside the volume the disk image is mounted at, so `du` walks the
/// unpacked contents of the runtime — a number that has nothing to do with what deleting it
/// gives back. The image reports its own `sizeBytes`, and that is the row's size.
///
/// The measurer is asserted on as well, because nothing in the returned item shows whether
/// `du` ran, and running it here is not merely wasted: it is a multi-gigabyte walk over a
/// mounted volume for a number that is then thrown away.
@Test func aRuntimeWithADiskImageIsSizedFromTheImageAndNotFromTheMountedBundle() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(
            identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", name: "iOS 26.5",
            version: "26.5", buildVersion: "23F77",
            bundlePath: "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/…/iOS 26.5.simruntime",
            images: [image("09A925DA-7B77-461C-B7E8-98E7F377116D",
                           build: "23F77", bytes: 8_494_282_293)]),
    ], avds: [])
    let measurer = CallCountingSizeMeasurer([
        "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/…/iOS 26.5.simruntime":
            17_300_000_000,
    ])

    let items = await SimulatorRuntimesScanner().scan(context(
        devices: devices, protection: protection(keptSimulator: nil),
        temp: temp, sizeMeasurer: measurer))

    let item = try #require(items.first)
    #expect(item.sizeBytes == 8_494_282_293)
    // The number the button is printed from. "Delete 17.3 GB for good" is what the user
    // pressed; "8.5 GB" is what was there.
    #expect(ByteText.short(item.sizeBytes) == "8.5 GB")
    #expect(item.isDeletable)
    #expect(!item.startsUnticked)

    let callCount = await measurer.callCount
    #expect(callCount == 0)
}

/// The over-fix guard. A bundle runtime has no image and no other source of a size, so `du`
/// still runs for it — and only for it.
@Test func onlyTheRuntimesWithoutADiskImageAreMeasuredWithDu() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
                         buildVersion: "23F77", bundlePath: "/rt/26.5",
                         images: [image("IMG-1", build: "23F77", bytes: 8_494_282_293)]),
        SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                         buildVersion: "22C150", bundlePath: "/rt/18.2"),
    ], avds: [])
    let measurer = CallCountingSizeMeasurer(["/rt/26.5": 16_000_000_000,
                                             "/rt/18.2": 7_000_000_000])

    let items = await SimulatorRuntimesScanner().scan(context(
        devices: devices, protection: protection(keptSimulator: nil),
        temp: temp, sizeMeasurer: measurer))

    #expect(items.count == 2)
    let withImage = try #require(items.first { $0.name == "iOS 26.5" })
    #expect(withImage.sizeBytes == 8_494_282_293)
    let bundleRuntime = try #require(items.first { $0.name == "iOS 18.2" })
    #expect(bundleRuntime.sizeBytes == 7_000_000_000)

    let batches = await measurer.batches
    #expect(batches == [["/rt/18.2"]])
}

/// Two images under one runtime add up rather than one of them being picked.
///
/// Reachable when two builds of one version are installed: they share a runtime identifier
/// — it is derived from the version — so `ScanEngine` merges their rows into one card, and
/// the executor answers that card by deleting both. A row showing one build's size would
/// promise half of what the click removes.
@Test func severalDiskImagesUnderOneRuntimeAreAddedUp() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
                         buildVersion: "23F77", bundlePath: "/rt/26.5",
                         images: [image("IMG-1", build: "23F77", bytes: 8_494_282_293),
                                  image("IMG-2", build: "23F77", bytes: 8_006_076_769)]),
    ], avds: [])

    let items = await SimulatorRuntimesScanner().scan(context(
        devices: devices, protection: protection(keptSimulator: nil), temp: temp,
        sizes: ["/rt/26.5": 17_300_000_000]))

    let item = try #require(items.first)
    #expect(item.sizeBytes == 16_500_359_062)
}

/// **A runtime whose image simctl will not delete is shown and never offered.**
///
/// This is the row that produced the bug report. Offering it is a button that fails after
/// the click: `simctl runtime delete` refuses, nothing is freed, and the user is told a
/// permanent deletion went wrong. Kept rather than dropped, because the space is real and a
/// card that measured 8.49 GB and then said nothing about it is how a user comes to believe
/// the tool's totals disagree with `du`.
@Test func aRuntimeWhoseDiskImageCannotBeDeletedIsShownWithItsSizeButNotOffered() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
                         buildVersion: "23F77", bundlePath: "/rt/26.5",
                         images: [image("IMG-1", build: "23F77", bytes: 8_494_282_293,
                                        deletable: false)]),
    ], avds: [])

    let items = await SimulatorRuntimesScanner().scan(context(
        devices: devices, protection: protection(keptSimulator: nil), temp: temp))

    let item = try #require(items.first)
    #expect(!item.isDeletable)
    #expect(item.protection == .runtimeImageNotDeletable)
    #expect(item.sizeBytes == 8_494_282_293)
    #expect(item.detail == "build 23F77 · the system will not delete this one")
    #expect(ReportText.mark(for: item) == "-")
}

/// One of two images refusing is enough. The row is one card and one click, and that click
/// would delete the deletable half and report the other half as a failure.
@Test func oneNonDeletableImageHoldsTheWholeRuntimeBack() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
                         buildVersion: "23F77", bundlePath: "/rt/26.5",
                         images: [image("IMG-1", build: "23F77", bytes: 8_494_282_293),
                                  image("IMG-2", build: "23F77", bytes: 8_006_076_769,
                                        deletable: false)]),
    ], avds: [])

    let items = await SimulatorRuntimesScanner().scan(context(
        devices: devices, protection: protection(keptSimulator: nil), temp: temp))

    let item = try #require(items.first)
    #expect(item.protection == .runtimeImageNotDeletable)
}

/// The resolver's reasons are not overwritten by this one.
///
/// They are the promises the app makes to the user — the newest runtime stays, the runtime a
/// kept simulator boots on stays — and they are also the ones the interface offers somewhere
/// to change one's mind about. "The system will not delete this one" instead would be a true
/// sentence in place of the useful one.
@Test func theResolversReasonOutranksANonDeletableImage() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
                         buildVersion: "23F77", bundlePath: "/rt/26.5",
                         images: [image("IMG-1", build: "23F77", bytes: 8_494_282_293,
                                        deletable: false)]),
    ], avds: [])

    let items = await SimulatorRuntimesScanner().scan(context(
        devices: devices,
        protection: protection(keptSimulator: nil,
                               runtimes: ["iOS-26-5": .runtimeUsedByKeptDevice]),
        temp: temp))

    let item = try #require(items.first)
    #expect(item.protection == .runtimeUsedByKeptDevice)
    #expect(item.detail == "build 23F77 · used by the simulator you keep")
}

/// A runtime with an image but no reported bundle path is offered, because the image is
/// where both its size and its deletion identifier come from.
///
/// `runtimeWithoutBundlePathIsSkippedBecauseItCannotBeMeasured` above is the same fixture
/// without an image, and it is still skipped: the bundle path mattered because it was the
/// only way to size a runtime, not for its own sake.
@Test func aRuntimeWithADiskImageAndNoBundlePathIsStillOffered() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                         buildVersion: "22C150", bundlePath: "",
                         images: [image("IMG-1", build: "22C150", bytes: 7_000_000_000)]),
    ], avds: [])

    let items = await SimulatorRuntimesScanner().scan(context(
        devices: devices, protection: protection(keptSimulator: nil), temp: temp))

    let item = try #require(items.first)
    #expect(item.sizeBytes == 7_000_000_000)
    #expect(item.isDeletable)
    #expect(!item.startsUnticked)
}

/// `sizes(of:)` batches its input and holds four `du` processes open at most, so
/// one call per runtime defeats that cap. Nothing in the items shows it.
@Test func runtimesAreMeasuredInOneBatchedCall() async throws {
    let temp = TempDir()
    let devices = DeviceInventory(simulators: [], runtimes: [
        SimulatorRuntime(identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
                         buildVersion: "23F77", bundlePath: "/rt/26.5"),
        SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                         buildVersion: "22C150", bundlePath: "/rt/18.2"),
    ], avds: [])
    let measurer = CallCountingSizeMeasurer(["/rt/26.5": 16_000_000_000, "/rt/18.2": 7_000_000_000])

    let items = await SimulatorRuntimesScanner().scan(context(
        devices: devices, protection: protection(keptSimulator: nil),
        temp: temp, sizeMeasurer: measurer))

    #expect(items.count == 2)
    let callCount = await measurer.callCount
    #expect(callCount == 1)
    let batches = await measurer.batches
    let batch = try #require(batches.first)
    #expect(batch.count == 2)
}

// MARK: caches

@Test func simulatorCachesAreOfferedWhenPresent() async throws {
    let temp = TempDir()
    let path = temp.makeDirectory("Library/Developer/CoreSimulator/Caches")
    let items = await SimulatorCachesScanner().scan(context(
        devices: .empty, protection: .empty, temp: temp, sizes: [path: 1_500_000_000]))
    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item.isDeletable)
    #expect(item.sizeBytes == 1_500_000_000)
    #expect(item.method == .removePath(path))
    #expect(item.id == "ios.simulatorCaches|\(path)")
}

@Test func simulatorCachesScannerIsSilentWhenTheDirectoryIsAbsent() async {
    let temp = TempDir()
    let items = await SimulatorCachesScanner()
        .scan(context(devices: .empty, protection: .empty, temp: temp))
    #expect(items.isEmpty)
}

// MARK: identity

/// The identifiers are persisted in `Settings.alwaysSkipScannerIDs`, so renaming
/// one silently un-skips it for an existing user.
@Test func simulatorScannerIdentitiesAndGroupsAreStable() {
    #expect(SimulatorDevicesScanner().id == "ios.simulators")
    #expect(SimulatorRuntimesScanner().id == "ios.runtimes")
    #expect(SimulatorCachesScanner().id == "ios.simulatorCaches")
    #expect(SimulatorDevicesScanner().group == .xcodeAndIOS)
    #expect(SimulatorRuntimesScanner().group == .xcodeAndIOS)
    #expect(SimulatorCachesScanner().group == .xcodeAndIOS)
}
