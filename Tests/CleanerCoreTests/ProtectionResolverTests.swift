import Testing
import Foundation
@testable import CleanerCore

private let now = Date(timeIntervalSince1970: 1_786_000_000)

private func settings(_ mutate: (inout Settings) -> Void = { _ in }) -> Settings {
    var value = Settings.makeDefault(home: "/Users/tester")
    mutate(&value)
    return value
}

private func simulator(
    _ udid: String, name: String, booted: Date?, runtime: String = "iOS-26-5",
    isBooted: Bool = false
) -> SimulatorDevice {
    SimulatorDevice(
        udid: udid, name: name, runtimeIdentifier: runtime, isBooted: isBooted,
        sizeBytes: 1_000, lastBootedAt: booted)
}

private func avd(_ name: String, used: Date?) -> AndroidAVD {
    AndroidAVD(name: name, directoryPath: "/avd/\(name).avd",
               lastUsed: used, systemImageRelativePath: nil)
}

@Test func projectChangedInsideTheWindowIsProtected() {
    let project = DiscoveredProject(path: "/dev/sample-project", name: "sample-project")
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [project],
        activity: ["/dev/sample-project": now.addingTimeInterval(-86_400 * 3)],
        devices: .empty, now: now)
    #expect(set.projects["/dev/sample-project"] == .recentActivity(days: 14))
}

@Test func projectOutsideTheWindowIsNotProtected() {
    let project = DiscoveredProject(path: "/dev/old", name: "old")
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [project],
        activity: ["/dev/old": now.addingTimeInterval(-86_400 * 40)],
        devices: .empty, now: now)
    #expect(set.projects["/dev/old"] == nil)
}

@Test func pinnedProjectIsProtectedEvenWhenAncient() {
    let project = DiscoveredProject(path: "/dev/old", name: "old")
    let configured = settings { $0.pinnedProjectPaths = ["/dev/old"] }
    let set = ProtectionResolver(settings: configured).resolve(
        projects: [project],
        activity: ["/dev/old": now.addingTimeInterval(-86_400 * 400)],
        devices: .empty, now: now)
    #expect(set.projects["/dev/old"] == .pinnedProject)
}

/// The cutoff is inclusive. `projectOutsideTheWindowIsNotProtected` pins the far
/// side, so between them these two fix `>=` and rule out `>`.
@Test func activityExactlyOnTheCutoffIsStillProtected() {
    let project = DiscoveredProject(path: "/dev/edge", name: "edge")
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [project],
        activity: ["/dev/edge": now.addingTimeInterval(-86_400 * 14)],
        devices: .empty, now: now)
    #expect(set.projects["/dev/edge"] == .recentActivity(days: 14))
}

@Test func projectWithNoActivityDateIsNotProtected() {
    let project = DiscoveredProject(path: "/dev/empty", name: "empty")
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [project], activity: [:], devices: .empty, now: now)
    #expect(set.projects["/dev/empty"] == nil)
}

@Test func keepsTheMostRecentlyBootedSimulator() {
    let devices = DeviceInventory(
        simulators: [
            simulator("AAA", name: "iPhone 17 Pro Max", booted: now.addingTimeInterval(-86_400 * 5)),
            simulator("BBB", name: "iPhone Air", booted: nil),
            simulator("CCC", name: "iPad Pro", booted: now.addingTimeInterval(-3_600)),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptSimulatorUDID == "CCC")
}

@Test func neverBootedSimulatorsAloneMeanNothingIsKept() {
    let devices = DeviceInventory(
        simulators: [simulator("AAA", name: "iPhone Air", booted: nil)],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptSimulatorUDID == nil)
    #expect(set.protectedSimulatorUDIDs.isEmpty)
}

@Test func aSingleBootedSimulatorIsTheOneKept() {
    let devices = DeviceInventory(
        simulators: [simulator("AAA", name: "iPhone 17 Pro", booted: now.addingTimeInterval(-600))],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptSimulatorUDID == "AAA")
}

@Test func noDevicesAtAllMeansNothingIsKept() {
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: .empty, now: now)
    #expect(set.keptSimulatorUDID == nil)
    #expect(set.keptAVDName == nil)
    #expect(set.protectedSimulatorUDIDs.isEmpty)
    #expect(set.protectedAVDNames.isEmpty)
}

/// A pin decides the *label* — which device is "the one you keep" — but it never
/// takes protection away from another device. Pinning a 90-day-old simulator must not
/// put today's simulator on the deletion list.
@Test func pinnedSimulatorOverridesMostRecentlyBooted() {
    let configured = settings { $0.pinnedSimulatorUDID = "AAA" }
    let devices = DeviceInventory(
        simulators: [
            simulator("AAA", name: "iPhone 17 Pro Max", booted: now.addingTimeInterval(-86_400 * 90)),
            simulator("CCC", name: "iPad Pro", booted: now),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: configured).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptSimulatorUDID == "AAA")
    #expect(set.protectedSimulatorUDIDs["AAA"] == .pinnedDevice)
    #expect(set.protectedSimulatorUDIDs["CCC"] == .mostRecentlyUsedDevice)
}

@Test func keepsTheMostRecentlyUsedAVD() {
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator_1", used: now.addingTimeInterval(-86_400 * 30)),
        avd("sample_emulator", used: now.addingTimeInterval(-86_400)),
        avd("sample_avd", used: nil),
    ])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptAVDName == "sample_emulator")
}

@Test func protectsNewestRuntimeAndTheOneUsedByTheKeptSimulator() {
    let devices = DeviceInventory(
        simulators: [simulator("AAA", name: "iPhone", booted: now, runtime: "iOS-18-2")],
        runtimes: [
            SimulatorRuntime(identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
                             buildVersion: "23F77", bundlePath: "/rt/26.5.simruntime"),
            SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                             buildVersion: "22C150", bundlePath: "/rt/18.2.simruntime"),
        ],
        avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.runtimeIdentifiers["iOS-26-5"] == .newestRuntime)
    #expect(set.runtimeIdentifiers["iOS-18-2"] == .runtimeUsedByKeptDevice)
}

/// **Two simulators, not one.** The test above cannot catch this: with a single simulator
/// "kept" and "protected" are the same device, so reading only `keptSimulatorUDID` passes.
///
/// When device protection widened from "the one most recently used" to "everything used in
/// the last `deviceRecentUseDays`", this half was left reading the single winner. A
/// simulator the app promised to keep could have its runtime ticked for
/// `simctl runtime delete` — leaving a simulator that is still installed and will not
/// boot. `SystemImagesScanner` was widened for exactly this on the Android side.
@Test func theRuntimeOfASimulatorKeptByTheRecentUseRuleIsProtectedToo() {
    let devices = DeviceInventory(
        simulators: [
            // The winner, on the newest runtime.
            simulator("WINNER", name: "iPad Pro", booted: now, runtime: "iOS-26-5"),
            // Kept by the 7-day rule alone, on a runtime nothing else uses.
            simulator("RECENT", name: "iPhone 17",
                      booted: now.addingTimeInterval(-86_400 * 3), runtime: "iOS-18-2"),
            // Offered, on a third runtime, which must stay offered with it.
            simulator("STALE", name: "sample-ios-simulator",
                      booted: now.addingTimeInterval(-86_400 * 30), runtime: "iOS-17-0"),
        ],
        runtimes: [
            SimulatorRuntime(identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
                             buildVersion: "23F77", bundlePath: "/rt/26.5.simruntime"),
            SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                             buildVersion: "22C150", bundlePath: "/rt/18.2.simruntime"),
            SimulatorRuntime(identifier: "iOS-17-0", name: "iOS 17.0", version: "17.0",
                             buildVersion: "21A328", bundlePath: "/rt/17.0.simruntime"),
        ],
        avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)

    // The kept device is protected, and keeps the more specific wording.
    #expect(set.protectedSimulatorUDIDs["RECENT"] == .recentlyUsedDevice(days: 7))
    #expect(set.runtimeIdentifiers["iOS-18-2"] == .runtimeUsedByProtectedDevice)
    #expect(set.runtimeIdentifiers["iOS-26-5"] == .newestRuntime)
    // The over-fix guard: the runtime of the one simulator that really is offered stays
    // offered. A rule that protected every installed runtime would pass the two above.
    #expect(set.runtimeIdentifiers["iOS-17-0"] == nil)
}

/// The same widening for a simulator kept only because it is running right now. Nothing
/// about its timestamp says it matters, so the runtime beneath it is the one most likely
/// to be swept up.
@Test func theRuntimeOfARunningSimulatorIsProtectedToo() {
    let devices = DeviceInventory(
        simulators: [
            simulator("WINNER", name: "iPad Pro", booted: now, runtime: "iOS-26-5"),
            simulator("RUNNING", name: "Sample Design Simulator",
                      booted: now.addingTimeInterval(-86_400 * 9),
                      runtime: "iOS-18-2", isBooted: true),
        ],
        runtimes: [
            SimulatorRuntime(identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
                             buildVersion: "23F77", bundlePath: "/rt/26.5.simruntime"),
            SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                             buildVersion: "22C150", bundlePath: "/rt/18.2.simruntime"),
        ],
        avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.runtimeIdentifiers["iOS-18-2"] == .runtimeUsedByProtectedDevice)
}

/// Two protected simulators sharing one runtime must always produce the same reason.
/// `Set` and `Dictionary` promise no iteration order, so an unsorted loop would make the
/// text change between scans for no reason the user can see.
@Test func aRuntimeSharedByTheKeptDeviceAndAnotherSaysItIsTheNewestInstalledRuntime() {
    let devices = DeviceInventory(
        simulators: [
            simulator("WINNER", name: "iPad Pro", booted: now, runtime: "iOS-18-2"),
            simulator("AAA", name: "iPhone 17",
                      booted: now.addingTimeInterval(-86_400 * 2), runtime: "iOS-18-2"),
            simulator("ZZZ", name: "iPhone Air",
                      booted: now.addingTimeInterval(-86_400 * 3), runtime: "iOS-18-2"),
        ],
        runtimes: [
            SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                             buildVersion: "22C150", bundlePath: "/rt/18.2.simruntime"),
        ],
        avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    // `.newestRuntime` wins here because it is the only runtime installed, which is also
    // the shape the fixture has — so the ordering rule is pinned by the next assertion
    // rather than this one.
    #expect(set.runtimeIdentifiers["iOS-18-2"] == .newestRuntime)
}

/// The ordering rule with the "newest runtime" reason out of the way, so the kept
/// device's wording is what has to win over the other protected device's.
@Test func theKeptDevicesWordingWinsOverAnotherProtectedDeviceOnTheSameRuntime() {
    let devices = DeviceInventory(
        simulators: [
            simulator("WINNER", name: "iPad Pro", booted: now, runtime: "iOS-18-2"),
            simulator("AAA", name: "iPhone 17",
                      booted: now.addingTimeInterval(-86_400 * 2), runtime: "iOS-18-2"),
        ],
        runtimes: [
            SimulatorRuntime(identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
                             buildVersion: "23F77", bundlePath: "/rt/26.5.simruntime"),
            SimulatorRuntime(identifier: "iOS-18-2", name: "iOS 18.2", version: "18.2",
                             buildVersion: "22C150", bundlePath: "/rt/18.2.simruntime"),
        ],
        avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.runtimeIdentifiers["iOS-18-2"] == .runtimeUsedByKeptDevice)
}

@Test func protectsFlutterVersionsNamedByAnyProjectIncludingUnprotectedOnes() {
    let temp = TempDir()
    temp.makeFile("dev/old/pubspec.yaml")
    temp.makeFile("dev/old/.fvmrc", contents: #"{"flutter":"3.10.6"}"#)
    temp.makeFile("dev/legacy/pubspec.yaml")
    temp.makeFile("dev/legacy/.fvm/fvm_config.json", contents: #"{"flutterSdkVersion":"3.24.5"}"#)

    let projects = [
        DiscoveredProject(path: temp.path + "/dev/old", name: "old"),
        DiscoveredProject(path: temp.path + "/dev/legacy", name: "legacy"),
    ]
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: projects,
        activity: [temp.path + "/dev/old": now.addingTimeInterval(-86_400 * 500)],
        devices: .empty, now: now)

    #expect(set.flutterVersions["3.10.6"] == .sdkInUse(by: "old"))
    #expect(set.flutterVersions["3.24.5"] == .sdkInUse(by: "legacy"))
}

@Test func protectsGradleVersionsOnlyForProtectedProjects() {
    let temp = TempDir()
    temp.makeFile("dev/active/pubspec.yaml")
    temp.makeFile("dev/active/android/gradle/wrapper/gradle-wrapper.properties",
        contents: "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.7-bin.zip\n")
    temp.makeFile("dev/stale/build.gradle")
    temp.makeFile("dev/stale/gradle/wrapper/gradle-wrapper.properties",
        contents: "distributionUrl=https\\://services.gradle.org/distributions/gradle-6.9-all.zip\n")

    let projects = [
        DiscoveredProject(path: temp.path + "/dev/active", name: "active"),
        DiscoveredProject(path: temp.path + "/dev/stale", name: "stale"),
    ]
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: projects,
        activity: [
            temp.path + "/dev/active": now.addingTimeInterval(-86_400),
            temp.path + "/dev/stale": now.addingTimeInterval(-86_400 * 300),
        ],
        devices: .empty, now: now)

    #expect(set.gradleDistributions["gradle-8.7-bin"] == .gradleVersionInUse(by: "active"))
    #expect(set.gradleDistributions["gradle-6.9-all"] == nil)
}

// MARK: recently used devices
//
// The rule the user chose: every device used in the last `deviceRecentUseDays`
// survives a default clean, not only the single newest one. On a real dev machine the
// old rule offered a 12.86 GB simulator booted 27 hours before the one it kept, and
// `simctl delete` has no Trash.

@Test func devicesUsedInsideTheWindowAreProtectedAndOlderOnesAreOffered() {
    let devices = DeviceInventory(
        simulators: [
            simulator("RECENT", name: "iPhone 17", booted: now.addingTimeInterval(-86_400 * 3)),
            simulator("WINNER", name: "Sample Design Simulator", booted: now),
            simulator("STALE", name: "sample-ios-simulator", booted: now.addingTimeInterval(-86_400 * 30)),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)

    #expect(set.keptSimulatorUDID == "WINNER")
    #expect(set.protectedSimulatorUDIDs["WINNER"] == .mostRecentlyUsedDevice)
    #expect(set.protectedSimulatorUDIDs["RECENT"] == .recentlyUsedDevice(days: 7))
    #expect(set.protectedSimulatorUDIDs["STALE"] == nil)
}

@Test func avdsUsedInsideTheWindowAreProtectedAndOlderOnesAreOffered() {
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator", used: now.addingTimeInterval(-86_400 * 3)),
        avd("Pixel_8_API_34", used: now),
        avd("sample_avd", used: now.addingTimeInterval(-86_400 * 30)),
    ])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)

    #expect(set.keptAVDName == "Pixel_8_API_34")
    #expect(set.protectedAVDNames["Pixel_8_API_34"] == .mostRecentlyUsedDevice)
    #expect(set.protectedAVDNames["sample_emulator"] == .recentlyUsedDevice(days: 7))
    #expect(set.protectedAVDNames["sample_avd"] == nil)
}

/// Both sides of the boundary in one test, with `deviceRecentUseDays` set to 3 rather
/// than the default 7. A hard-coded 7 in the resolver passes a test built on the
/// default value; it cannot pass this one, and the day count in the reason proves the
/// number reached the label as well as the comparison.
@Test func theRecentUseWindowComesFromSettingsAndIncludesItsBoundary() {
    let configured = settings { $0.deviceRecentUseDays = 3 }
    let devices = DeviceInventory(
        simulators: [
            simulator("WINNER", name: "iPad Pro", booted: now),
            simulator("EDGE", name: "iPhone 17", booted: now.addingTimeInterval(-86_400 * 3)),
            simulator("PAST", name: "iPhone Air", booted: now.addingTimeInterval(-86_400 * 3 - 1)),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: configured).resolve(
        projects: [], activity: [:], devices: devices, now: now)

    #expect(set.protectedSimulatorUDIDs["EDGE"] == .recentlyUsedDevice(days: 3))
    #expect(set.protectedSimulatorUDIDs["PAST"] == nil)
    #expect(set.protectedSimulatorUDIDs["WINNER"] == .mostRecentlyUsedDevice)
}

// MARK: a simulator that is running right now
//
// `lastBootedAt` records when a boot **started**, not when the device was last touched.
// Leave a simulator running for eight days and every timestamp rule above reads it as
// untouched for over a week, so it is offered — and `simctl delete` destroys the device
// directory: every installed app, its databases, its user defaults, its keychain. No
// Trash, no undo. Until this fix `isBooted` was read in exactly one place in the whole
// package, by the code that shut the device down in order to delete it.

/// The real sequence: boot a simulator, keep working in it, boot a different one at some
/// point in the next week, clean on day 8. Every date here is outside
/// `deviceRecentUseDays`, so nothing but `isBooted` can save it.
@Test func aSimulatorRunningNowIsProtectedEvenWhenItsBootMomentIsOlderThanTheWindow() {
    let devices = DeviceInventory(
        simulators: [
            simulator("RUNNING", name: "Sample Design Simulator",
                      booted: now.addingTimeInterval(-86_400 * 9), isBooted: true),
            simulator("WINNER", name: "iPhone 17", booted: now.addingTimeInterval(-86_400 * 8)),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)

    #expect(set.protectedSimulatorUDIDs["RUNNING"] == .bootedDevice)
    // The label is unchanged: being booted adds protection, it does not rename the winner.
    #expect(set.keptSimulatorUDID == "WINNER")
}

/// The over-fix guard. A rule that protected every simulator would pass the test above
/// and quietly stop the tool reclaiming anything at all — 12.9 GB per device here.
@Test func aSimulatorThatIsNotRunningAndIsOldIsStillOffered() {
    let devices = DeviceInventory(
        simulators: [
            simulator("RUNNING", name: "Sample Design Simulator",
                      booted: now.addingTimeInterval(-86_400 * 9), isBooted: true),
            simulator("STALE", name: "sample-ios-simulator", booted: now.addingTimeInterval(-86_400 * 30)),
            simulator("WINNER", name: "iPhone 17", booted: now.addingTimeInterval(-86_400 * 8)),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)

    #expect(set.protectedSimulatorUDIDs["STALE"] == nil)
    #expect(Set(set.protectedSimulatorUDIDs.keys) == ["RUNNING", "WINNER"])
}

/// Running beats every other reason in the text it shows, because it is the only reason
/// that cannot be out of date. A device that is both pinned and booted still says so.
@Test func runningNowIsTheReasonShownEvenWhenAnotherRuleAlsoMatches() {
    let configured = settings { $0.pinnedSimulatorUDID = "RUNNING" }
    let devices = DeviceInventory(
        simulators: [
            simulator("RUNNING", name: "Sample Design Simulator", booted: now, isBooted: true),
            simulator("OTHER", name: "iPhone 17", booted: now.addingTimeInterval(-86_400 * 30)),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: configured).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.protectedSimulatorUDIDs["RUNNING"] == .bootedDevice)
}

/// A simulator that has never recorded a boot but is running right now. It can never be
/// the newest, never be recent and never tie, so only a check against the full device
/// list — not the dated subset — reaches it.
@Test func aRunningSimulatorWithNoBootTimestampIsStillProtected() {
    let devices = DeviceInventory(
        simulators: [
            simulator("RUNNING", name: "iPhone Air", booted: nil, isBooted: true),
            simulator("WINNER", name: "iPad Pro", booted: now),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.protectedSimulatorUDIDs["RUNNING"] == .bootedDevice)
}

// MARK: indistinguishable devices
//
// A device cannot be moved to the Trash. When two of them are effectively tied,
// naming one the winner and deleting the other is a coin flip on something that
// cannot be undone, so both must survive.
//
// Every fixture here is older than `deviceRecentUseDays`, because that is the only
// regime where the two-second window still decides anything. With fresh timestamps
// the recent-use rule would protect both devices whatever the window did, and the
// tests would pass with the window deleted.

private let ancient = now.addingTimeInterval(-86_400 * 30)

@Test func simulatorsOneSecondApartAreBothIndistinguishable() {
    let devices = DeviceInventory(
        simulators: [
            simulator("AAA", name: "iPhone 17 Pro", booted: ancient.addingTimeInterval(-1)),
            simulator("BBB", name: "iPad Pro", booted: ancient),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptSimulatorUDID == "BBB")
    #expect(set.protectedSimulatorUDIDs["BBB"] == .mostRecentlyUsedDevice)
    #expect(set.protectedSimulatorUDIDs["AAA"] == .mostRecentlyUsedDevice)
}

@Test func simulatorsTenSecondsApartAreTellableApart() {
    let devices = DeviceInventory(
        simulators: [
            simulator("AAA", name: "iPhone 17 Pro", booted: ancient.addingTimeInterval(-10)),
            simulator("BBB", name: "iPad Pro", booted: ancient),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptSimulatorUDID == "BBB")
    #expect(Set(set.protectedSimulatorUDIDs.keys) == ["BBB"])
}

/// A pin names which device is "the one you keep". It must not remove protection from
/// a device that is newer — pinning is the user adding a guarantee, never withdrawing
/// one, and the newer device would otherwise be deleted permanently.
@Test func pinningASimulatorDoesNotExposeTheNewerOne() {
    let configured = settings { $0.pinnedSimulatorUDID = "AAA" }
    let devices = DeviceInventory(
        simulators: [
            simulator("AAA", name: "iPhone 17 Pro", booted: ancient.addingTimeInterval(-1)),
            simulator("BBB", name: "iPad Pro", booted: ancient),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: configured).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptSimulatorUDID == "AAA")
    #expect(set.protectedSimulatorUDIDs["AAA"] == .pinnedDevice)
    #expect(set.protectedSimulatorUDIDs["BBB"] == .mostRecentlyUsedDevice)
}

@Test func avdsOneSecondApartAreBothIndistinguishable() {
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator", used: ancient.addingTimeInterval(-1)),
        avd("Pixel_8_API_34", used: ancient),
    ])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptAVDName == "Pixel_8_API_34")
    #expect(set.protectedAVDNames["Pixel_8_API_34"] == .mostRecentlyUsedDevice)
    #expect(set.protectedAVDNames["sample_emulator"] == .mostRecentlyUsedDevice)
}

/// Exactly on the window, so it fixes the strict `<` and rules out `<=`. Together
/// with the one- and ten-second tests the 2-second value is pinned from both sides.
@Test func simulatorsExactlyTwoSecondsApartAreTellableApart() {
    let devices = DeviceInventory(
        simulators: [
            simulator("AAA", name: "iPhone 17 Pro", booted: ancient.addingTimeInterval(-2)),
            simulator("BBB", name: "iPad Pro", booted: ancient),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptSimulatorUDID == "BBB")
    #expect(Set(set.protectedSimulatorUDIDs.keys) == ["BBB"])
}

// MARK: pinned devices

/// The AVD half of `pinnedSimulatorOverridesMostRecentlyBooted`. Without it the whole
/// pinned branch of `resolveAVDs` can be deleted and every test still passes, which
/// would delete a user's explicitly pinned emulator with no way to get it back.
@Test func pinnedAVDOverridesMostRecentlyUsed() {
    let configured = settings { $0.pinnedAVDName = "sample_emulator_1" }
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator_1", used: now.addingTimeInterval(-86_400 * 90)),
        avd("sample_emulator", used: now),
    ])
    let set = ProtectionResolver(settings: configured).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptAVDName == "sample_emulator_1")
    #expect(set.protectedAVDNames["sample_emulator_1"] == .pinnedDevice)
    #expect(set.protectedAVDNames["sample_emulator"] == .mostRecentlyUsedDevice)
}

/// Pinning is the only way a device with no timestamp is ever protected. It can never
/// be the newest, never be recent and never tie, so without the pin check reading the
/// full device list this emulator would be offered.
@Test func pinnedDeviceThatWasNeverUsedIsStillProtected() {
    let configured = settings { $0.pinnedSimulatorUDID = "AAA" }
    let devices = DeviceInventory(
        simulators: [
            simulator("AAA", name: "iPhone Air", booted: nil),
            simulator("BBB", name: "iPad Pro", booted: ancient),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: configured).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptSimulatorUDID == "AAA")
    #expect(set.protectedSimulatorUDIDs["AAA"] == .pinnedDevice)
}

/// A pin left behind by a device the user already deleted must not be honoured. If the
/// existence guard broke, the phantom would be reported as kept and the newest real
/// device would fall through to deletable.
@Test func pinNamingASimulatorThatNoLongerExistsFallsBackToTheNewest() {
    let configured = settings { $0.pinnedSimulatorUDID = "GHOST" }
    let devices = DeviceInventory(
        simulators: [
            simulator("AAA", name: "iPhone 17 Pro Max", booted: ancient),
            simulator("CCC", name: "iPad Pro", booted: now),
        ],
        runtimes: [], avds: [])
    let set = ProtectionResolver(settings: configured).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptSimulatorUDID == "CCC")
    #expect(Set(set.protectedSimulatorUDIDs.keys) == ["CCC"])
    #expect(set.protectedSimulatorUDIDs["GHOST"] == nil)
}

@Test func pinNamingAnAVDThatNoLongerExistsFallsBackToTheNewest() {
    let configured = settings { $0.pinnedAVDName = "deleted_emulator" }
    let devices = DeviceInventory(simulators: [], runtimes: [], avds: [
        avd("sample_emulator_1", used: now.addingTimeInterval(-86_400 * 30)),
        avd("sample_emulator", used: now),
    ])
    let set = ProtectionResolver(settings: configured).resolve(
        projects: [], activity: [:], devices: devices, now: now)
    #expect(set.keptAVDName == "sample_emulator")
    #expect(Set(set.protectedAVDNames.keys) == ["sample_emulator"])
    #expect(set.protectedAVDNames["deleted_emulator"] == nil)
}

// MARK: gradle wrapper parsing

/// The commented-out lines name distributions the project does not use, so protecting
/// them would keep folders nothing needs.
@Test func readsMultiPartGradleVersionsAndIgnoresCommentedOutLines() {
    let temp = TempDir()
    temp.makeFile("dev/active/pubspec.yaml")
    temp.makeFile("dev/active/android/gradle/wrapper/gradle-wrapper.properties", contents: """
        #distributionUrl=https\\://services.gradle.org/distributions/gradle-6.9-all.zip
          # distributionUrl=https\\://services.gradle.org/distributions/gradle-5.1-bin.zip
        distributionUrl=https\\://services.gradle.org/distributions/gradle-8.7.1-all.zip
        """)

    let projects = [
        DiscoveredProject(path: temp.path + "/dev/active", name: "active")
    ]
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: projects,
        activity: [temp.path + "/dev/active": now.addingTimeInterval(-86_400)],
        devices: .empty, now: now)

    #expect(set.gradleDistributions["gradle-8.7.1-all"] == .gradleVersionInUse(by: "active"))
    #expect(set.gradleDistributions["gradle-6.9-all"] == nil)
    #expect(set.gradleDistributions["gradle-5.1-bin"] == nil)
}

/// The key is the whole distribution folder name, never the version.
///
/// A pre-release, a milestone and a nightly all reduce to a plain release number under
/// a version key: `gradle-9.0-rc-1-bin.zip` becomes `9.0`, which then also matches the
/// released `gradle-9.0-bin` sitting next to it in `~/.gradle/wrapper/dists`. A project
/// on the release candidate would protect the release and leave its own distribution
/// offered — 150 MB back over the network on its next build.
@Test func gradleKeyIsTheWholeDistributionNameNotJustTheVersion() {
    let cases = [
        ("gradle-9.0-rc-1-bin.zip", "gradle-9.0-rc-1-bin", "9.0"),
        ("gradle-8.0-milestone-1-bin.zip", "gradle-8.0-milestone-1-bin", "8.0"),
        ("gradle-8.9-20240611000000+0000-bin.zip", "gradle-8.9-20240611000000+0000-bin", "8.9"),
        ("gradle-8.14-all.zip", "gradle-8.14-all", "8.14"),
    ]
    for (file, expected, truncated) in cases {
        let line = "distributionUrl=https\\://services.gradle.org/distributions/\(file)"
        #expect(ProtectionResolver.gradleDistribution(fromDistributionURL: line) == expected)
        #expect(ProtectionResolver.gradleDistribution(fromDistributionURL: line) != truncated)
    }
}

/// A `-bin` and an `-all` distribution of the same version are two separate downloads
/// that sit side by side. A version key could not tell them apart, so naming one
/// protected both.
@Test func gradleBinAndAllOfTheSameVersionAreDifferentKeys() {
    let temp = TempDir()
    temp.makeFile("dev/active/build.gradle")
    temp.makeFile("dev/active/gradle/wrapper/gradle-wrapper.properties",
        contents: "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.14-all.zip\n")

    let projects = [
        DiscoveredProject(path: temp.path + "/dev/active", name: "active")
    ]
    let set = ProtectionResolver(settings: settings()).resolve(
        projects: projects,
        activity: [temp.path + "/dev/active": now.addingTimeInterval(-86_400)],
        devices: .empty, now: now)

    #expect(set.gradleDistributions["gradle-8.14-all"] == .gradleVersionInUse(by: "active"))
    #expect(set.gradleDistributions["gradle-8.14-bin"] == nil)
}
