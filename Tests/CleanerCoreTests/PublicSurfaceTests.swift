import Testing
import Foundation
// Deliberately NOT `@testable`. Every other file in this target uses `@testable import`,
// which lifts `internal` to visible and hides the whole problem this file exists to catch:
// a `public struct` gets no `public` memberwise initialiser, so a type that is public in
// name can be impossible to construct from another module. The menu bar app target hit
// exactly that as a compile error on `SimulatorDevice`.
//
// If one of these initialisers loses its `public`, this file stops compiling.
import CleanerCore

@Test func theDeviceAndProtectionTypesCanBeBuiltFromAnotherModule() {
    let device = SimulatorDevice(
        udid: "AAA", name: "iPhone 17 Pro", runtimeIdentifier: "iOS-26-5",
        isBooted: true, sizeBytes: 7_090_000_000,
        lastBootedAt: Date(timeIntervalSince1970: 1_786_000_000))
    #expect(device.isBooted)
    #expect(device.sizeBytes == 7_090_000_000)

    // With its disk image, which is what `simctl runtime delete` is really handed and what
    // the row's size comes from. `images` has a default, so the call above this comment —
    // every existing one — still compiles; this is the other half of the surface.
    let runtime = SimulatorRuntime(
        identifier: "iOS-26-5", name: "iOS 26.5", version: "26.5",
        buildVersion: "23F77", bundlePath: "/rt/26.5.simruntime",
        images: [SimulatorRuntimeImage(
            identifier: "09A925DA-7B77-461C-B7E8-98E7F377116D", build: "23F77",
            sizeBytes: 8_494_282_293, deletable: true, state: "Ready")])
    #expect(runtime.identifier == "iOS-26-5")
    #expect(runtime.imageSizeBytes == 8_494_282_293)
    #expect(runtime.everyImageIsDeletable)

    let avd = AndroidAVD(
        name: "Pixel_8_API_34", directoryPath: "/avd/Pixel_8_API_34.avd",
        lastUsed: nil, systemImageRelativePath: "system-images/android-34/google_apis/arm64-v8a")
    #expect(avd.name == "Pixel_8_API_34")

    let inventory = DeviceInventory(simulators: [device], runtimes: [runtime], avds: [avd])
    #expect(inventory.simulators.count == 1)

    let set = ProtectionSet(
        projects: ["/dev/sample-project": .pinnedProject],
        keptSimulatorUDID: "AAA", keptAVDName: nil,
        protectedSimulatorUDIDs: ["AAA": .bootedDevice],
        protectedAVDNames: [:],
        flutterVersions: [:], gradleDistributions: [:],
        runtimeIdentifiers: ["iOS-26-5": .runtimeUsedByKeptDevice])
    #expect(set.protectedSimulatorUDIDs["AAA"] == .bootedDevice)
    #expect(set.projects["/dev/sample-project"] == .pinnedProject)

    // A `DiscoveredProject` too: `CleanerService.clean` takes the paths of these, so an
    // app that wants to preview a scan has to be able to build one.
    let project = DiscoveredProject(path: "/dev/sample-project", name: "sample-project")
    #expect(project.name == "sample-project")
}

/// Everything the checklist card is built out of has to be reachable **without**
/// `@testable`, because that is the import `DevCleanerUI` and `DevCleanerApp` really have.
///
/// The deck recognises the page by `DeckDealing.checklist` off `ScannerInfo.dealing`, and
/// recognises a row as one of the user's own files by the scanner's identifier. Both were
/// added for this feature, and a `public enum` case or a `public static let` that is
/// reachable only under `@testable` is a compile error in the app target and nowhere else —
/// which is exactly how `SimulatorDevice`'s missing initialiser was found.
@Test func theChecklistCardsContractIsReachableFromAnotherModule() {
    #expect(LargeFilesScanner.scannerID == "big.largeFiles")
    #expect(LargeFilesScanner().deckDealing == DeckDealing.checklist)

    let info = CleanerService.scanner(withID: LargeFilesScanner.scannerID)
    #expect(info?.dealing == .checklist)
    #expect(info?.title == "Large files")
    #expect(info?.group == .bigThings)
}

/// `TildePath` has to be reachable from another module or there would be two expansions
/// again: `SettingsModel.addProjectRoot` lives in `DevCleanerUI` and has to expand the same
/// way the engine does, or the root on screen and the root the engine walks are two
/// different directories. Checked here, without `@testable`, because that is the import the
/// app really has.
@Test func theTildeExpansionIsReachableFromAnotherModule() {
    #expect(TildePath.expanded("~/dev", home: "/Users/tester") == "/Users/tester/dev")
}
