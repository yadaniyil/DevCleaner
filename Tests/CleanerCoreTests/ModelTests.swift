import Testing
import Foundation
@testable import CleanerCore

@Test func deletableItemIsSelectedByDefaultAndProtectedItemIsNot() {
    let deletable = CleanupItem(
        id: "a", scannerID: "xcode.derivedData", group: .xcodeAndIOS,
        name: "MyApp-abc", detail: nil, sizeBytes: 1_000, lastUsed: nil,
        risk: .safe, protection: nil, method: .removePath("/tmp/x"))
    let kept = CleanupItem(
        id: "b", scannerID: "ios.simulators", group: .xcodeAndIOS,
        name: "iPhone 17 Pro", detail: nil, sizeBytes: 2_000, lastUsed: nil,
        risk: .safe, protection: .mostRecentlyUsedDevice,
        method: .deleteSimulator(udid: "UDID"))

    #expect(deletable.isDeletable)
    #expect(deletable.selectedByDefault)
    #expect(!kept.isDeletable)
    #expect(!kept.selectedByDefault)
}

@Test func elevatedRiskItemIsStillSelectedByDefault() {
    let item = CleanupItem(
        id: "c", scannerID: "flutter.pubCache", group: .flutterAndDart,
        name: "pub-cache", detail: nil, sizeBytes: 8_700_000_000, lastUsed: nil,
        risk: .elevated, protection: nil, method: .removePath("/tmp/pub"))
    #expect(item.selectedByDefault)
}

/// The field Task 16b added. Deletable and unticked are two different things: the row is
/// shown with its size and can be removed, but a default clean leaves it alone until the
/// user ticks it. `android.ndk` is the only scanner that asks for it today.
@Test func anUntickedItemIsStillDeletableButIsNotSelectedByDefault() {
    let ndk = CleanupItem(
        id: "e", scannerID: "android.ndk", group: .android,
        name: "28.2.13676358", detail: nil, sizeBytes: 2_970_000_000, lastUsed: nil,
        risk: .elevated, protection: nil, method: .removePath("/tmp/ndk/28.2.13676358"),
        startsUnticked: true)

    #expect(ndk.isDeletable)
    #expect(!ndk.selectedByDefault)
}

/// The default has to leave every row that existed before the field untouched, and the
/// argument has a default value so that no existing call site had to change — which is
/// exactly how a wrong default would go unnoticed.
@Test func anItemThatDoesNotAskToBeUntickedIsTickedAsBefore() {
    let item = CleanupItem(
        id: "f", scannerID: "android.gradle", group: .android,
        name: "Downloaded dependencies", detail: nil, sizeBytes: 3_000_000_000,
        lastUsed: nil, risk: .elevated, protection: nil, method: .removePath("/tmp/g"))
    #expect(!item.startsUnticked)
    #expect(item.selectedByDefault)
}

/// A `ScanResult` written before `startsUnticked` existed has no such key. A synthesised
/// decoder fails the whole document over it; this one reads the missing value as `false`,
/// which is what every row written back then meant.
@Test func anItemEncodedBeforeTheUntickedFieldExistedStillDecodes() throws {
    let json = """
    {"id":"g","scannerID":"android.gradle","group":"android","name":"Daemon logs",
     "sizeBytes":1000,"risk":"safe","method":{"removePath":{"_0":"/tmp/d"}}}
    """
    let decoded = try JSONDecoder().decode(CleanupItem.self, from: Data(json.utf8))
    #expect(!decoded.startsUnticked)
    #expect(decoded.selectedByDefault)
    #expect(decoded.method == .removePath("/tmp/d"))
    #expect(decoded.detail == nil)
    #expect(decoded.lastUsed == nil)
    #expect(decoded.protection == nil)
}

@Test func theUntickedFlagSurvivesAJSONRoundTrip() throws {
    let item = CleanupItem(
        id: "h", scannerID: "android.ndk", group: .android,
        name: "27.0.12077973", detail: "native builds", sizeBytes: 2_600_000_000,
        lastUsed: nil, risk: .elevated, protection: nil,
        method: .removePath("/tmp/ndk/27.0.12077973"), startsUnticked: true)
    let decoded = try JSONDecoder().decode(
        CleanupItem.self, from: try JSONEncoder().encode(item))
    #expect(decoded == item)
    #expect(decoded.startsUnticked)
}

@Test func protectionReasonHasHumanReadableText() {
    #expect(ProtectionReason.recentActivity(days: 14).description
            == "changed in the last 14 days")
    #expect(ProtectionReason.pinnedProject.description == "pinned")
    #expect(ProtectionReason.mostRecentlyUsedDevice.description == "most recently used")
    #expect(ProtectionReason.sdkInUse(by: "sample-project").description == "used by sample-project")
}

@Test func cleanupItemSurvivesJSONRoundTrip() throws {
    let item = CleanupItem(
        id: "d", scannerID: "android.avds", group: .android,
        name: "sample_emulator_1", detail: "last used 3 Jun", sizeBytes: 6_400_000_000,
        lastUsed: Date(timeIntervalSince1970: 1_780_000_000),
        risk: .safe, protection: nil, method: .deleteAVD(name: "sample_emulator_1"))
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(CleanupItem.self, from: data)
    #expect(decoded == item)
}

/// The two reasons added by this fix wave carry their own words and survive storage.
///
/// `ProtectionReason` is encoded inside every cached `CleanupItem`, so a new case has to
/// round-trip, and — the direction that has bitten this project three times — a document
/// written **before** the case existed has to keep decoding. Adding a case cannot break
/// that, and the second half of this test is what proves it rather than assuming it.
@Test func theNewProtectionReasonsRoundTripAndOlderRowsStillDecode() throws {
    #expect(ProtectionReason.bootedDevice.description == "running right now")
    #expect(ProtectionReason.runtimeUsedByProtectedDevice.description
            == "used by a simulator that is kept")

    let item = CleanupItem(
        id: "ios.simulators|AAA", scannerID: "ios.simulators", group: .xcodeAndIOS,
        name: "Sample Design Simulator", detail: "running right now", sizeBytes: 7_090_000_000,
        lastUsed: Date(timeIntervalSince1970: 1_785_000_000),
        risk: .elevated, protection: .bootedDevice, method: .deleteSimulator(udid: "AAA"))
    let decoded = try JSONDecoder().decode(
        CleanupItem.self, from: try JSONEncoder().encode(item))
    #expect(decoded == item)
    #expect(decoded.protection == .bootedDevice)

    // A row stored by a build that had neither new case, and neither soft key. Every
    // value it did carry has to come back, and `startsUnticked` has to read as false —
    // which is what every row written before that field meant.
    let old = Data("""
        {"id":"ios.simulators|BBB","scannerID":"ios.simulators","group":"xcodeAndIOS",
         "name":"iPhone 17","sizeBytes":12860000000,"risk":"safe",
         "protection":{"recentlyUsedDevice":{"days":7}},
         "method":{"deleteSimulator":{"udid":"BBB"}}}
        """.utf8)
    let older = try JSONDecoder().decode(CleanupItem.self, from: old)
    #expect(older.protection == .recentlyUsedDevice(days: 7))
    #expect(older.method == .deleteSimulator(udid: "BBB"))
    #expect(!older.startsUnticked)
    #expect(!older.sizeMayBeShared)
    #expect(older.sizeBytes == 12_860_000_000)
}

@Test func freeSpaceOnRootVolumeIsPositive() throws {
    #expect(try FreeSpace.availableBytes(forVolumeContaining: "/") > 0)
}
