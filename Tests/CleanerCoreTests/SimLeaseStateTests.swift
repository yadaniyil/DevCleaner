import Testing
import Foundation
@testable import CleanerCore

private let now = Date(timeIntervalSince1970: 1_786_000_000)

/// The three Simulators pinned on a real dev machine, in the shape that file really has:
/// a header, and a comment after every UDID.
private let signedIn = "5D2E8A10-7C41-4B9E-9F3A-1C6B0E2D4A71"
private let capturePhone = "3F7B9C21-0D4E-4A88-B5C2-7E1F6A9D3B40"
private let captureTablet = "9A4C2E70-5B13-4F6D-A8E9-2C0B7D5F1E36"

/// A lease file exactly as SimLease's `write_metadata` writes it, schema 3. Only `udid`,
/// `deviceName`, `owner` and `expiresAtEpoch` are read; the rest is there so a reader that
/// trips over a field it does not expect fails here rather than on a real Mac.
private func leaseJSON(udid: String, deviceName: String, owner: String,
                       expiresAt: Date = now.addingTimeInterval(3_600)) -> String {
    let epoch = Int(expiresAt.timeIntervalSince1970)
    return """
    {
      "schemaVersion": 3,
      "udid": "\(udid)",
      "deviceName": "\(deviceName)",
      "owner": "\(owner)",
      "purpose": "Test the settings screen",
      "workspace": "/Users/tester/dev/app",
      "tokenHash": "4f1c0e",
      "acquiredAt": "2026-08-06T09:00:00Z",
      "acquiredAtEpoch": \(epoch - 3_600),
      "expiresAt": "2026-08-06T10:00:00Z",
      "expiresAtEpoch": \(epoch),
      "ttlSeconds": 3600,
      "lockPid": 4242,
      "guardPid": 4243,
      "guardLabel": "com.simlease.guard.4f1c0e",
      "bootedBySimLease": true,
      "lifecycleState": "leased",
      "derivedDataPath": "/tmp/simlease/derived-data/abc/\(udid)"
    }
    """
}

private func read(_ temp: TempDir) -> SimLeaseState {
    simLeaseReader(in: temp).read(now: now)
}

// MARK: - the pinned file

@Test func thePinnedFileKeepsItsUDIDsAndDropsCommentsBlankLinesAndWhitespace() {
    let contents = """
    # Simulator UDIDs automatic simlease picks skip (signed in, seeded media).
    # One per line; `simlease acquire --device <UDID>` still leases them.

    \(signedIn)  # qa-01: signed in to the test account
    \t\(capturePhone)\t# capture iPhone: exactly the ten stock clips
       \(captureTablet)   \r
    #\(String(repeating: "0", count: 36)) commented out, so not pinned
         \t
    """
    #expect(SimLeaseReader.pinnedUDIDs(inPinnedFile: contents)
        == [signedIn, capturePhone, captureTablet])
}

/// The script strips **every** whitespace character from a line, not only the ends, so a
/// UDID with a stray space inside it is still that UDID. Matching the script matters more
/// than tidiness here: a line SimLease reads as a pin must be one this app reads as a pin.
@Test func whitespaceInsideALineIsDroppedTheWayTheScriptDropsIt() {
    #expect(SimLeaseReader.pinnedUDIDs(inPinnedFile: "5D2E8A10-7C41-4B9E-9F3A -1C6B0E2D4A71\n")
        == [signedIn])
}

@Test func aPinnedFileOfOnlyCommentsAndBlankLinesPinsNothing() {
    #expect(SimLeaseReader.pinnedUDIDs(inPinnedFile: "# nothing yet\n\n   \n\t# still nothing\n")
        .isEmpty)
    #expect(SimLeaseReader.pinnedUDIDs(inPinnedFile: "").isEmpty)
}

/// simctl prints UDIDs upper case and SimLease compares them exactly, so a pin typed in
/// lower case is one SimLease itself would skip. It is still somebody writing "keep this"
/// in a file, and reading it costs a device that stays.
@Test func aLowerCaseUDIDInThePinnedFileStillPinsTheSimulator() {
    let temp = TempDir()
    temp.makeFile(".config/simlease/pinned", contents: signedIn.lowercased() + "  # qa-01\n")

    let state = read(temp)
    #expect(state.pinnedUDIDs == [signedIn])
    #expect(state.definiteReason(forSimulator: signedIn) == .pinnedInSimLease)
    #expect(state.definiteReason(forSimulator: signedIn.lowercased()) == .pinnedInSimLease)
    // The over-fix guard: another Simulator is not pinned by it.
    #expect(state.definiteReason(forSimulator: capturePhone) == nil)
}

@Test func everyPinnedFileIsReadAndTheirUDIDsAreAddedTogether() {
    let temp = TempDir()
    let first = temp.makeFile("config-a/pinned", contents: signedIn + "\n")
    let second = temp.makeFile("config-b/pinned", contents: capturePhone + "\n")
    let reader = SimLeaseReader(
        pinnedFiles: [first, temp.path + "/missing/pinned", second], leaseDirectories: [])

    let state = reader.read(now: now)
    #expect(state.pinnedUDIDs == [signedIn, capturePhone])
    // A pinned file that is not there is the ordinary case — SimLease is not installed, or
    // nothing was ever pinned — and is not a doubt about anything.
    #expect(!state.simulatorsInDoubt)
}

/// A pinned file that exists and cannot be read names Simulators this app cannot see, so
/// every Simulator is in doubt. The alternative is deleting qa-01 because a permission bit
/// was wrong.
@Test func aPinnedFileThatCannotBeReadPutsEverySimulatorInDoubt() {
    let temp = TempDir()
    // A directory where the file should be: `fileExists` says yes, `contents` says nil.
    temp.makeDirectory(".config/simlease/pinned")

    let state = read(temp)
    #expect(state.simulatorsInDoubt)
    #expect(!state.emulatorsInDoubt)
    #expect(state.definiteReason(forSimulator: signedIn) == nil)
    #expect(state.reason(forSimulator: signedIn) == .simLeaseUnreadable)
}

// MARK: - leases

/// SimLease is not installed, or has never taken a lease: no config directory, no lease
/// directory. That is an answer — nothing is held — and never a doubt.
@Test func noSimLeaseAtAllHoldsNothingAndDoubtsNothing() {
    let temp = TempDir()
    let state = read(temp)
    #expect(state == .empty)
    #expect(state.reason(forSimulator: signedIn) == nil)
    #expect(state.reason(forAVD: "work_avd") == nil)
}

@Test func anEmptyLeaseDirectoryHoldsNothing() {
    let temp = TempDir()
    temp.makeDirectory("simlease/leases")
    #expect(read(temp) == .empty)
}

@Test func aSimulatorLeaseNamesItsDeviceAndItsOwner() throws {
    let temp = TempDir()
    temp.makeFile("simlease/leases/\(capturePhone).json", contents: leaseJSON(
        udid: capturePhone, deviceName: "iPhone 17 Pro Max", owner: "capture-agent"))

    let state = read(temp)
    let lease = try #require(state.leases.first)
    #expect(state.leases.count == 1)
    #expect(lease.deviceID == capturePhone)
    #expect(lease.deviceName == "iPhone 17 Pro Max")
    #expect(lease.owner == "capture-agent")
    #expect(lease.expiresAt == now.addingTimeInterval(3_600))
    #expect(!lease.isEmulator)
    #expect(state.definiteReason(forSimulator: capturePhone)
        == .leasedInSimLease(owner: "capture-agent"))
    #expect(ProtectionReason.leasedInSimLease(owner: "capture-agent").description
        == "leased by capture-agent in SimLease")
    // A Simulator lease says nothing about emulators.
    #expect(state.reason(forAVD: "iPhone 17 Pro Max") == nil)
}

/// A lease beats a pin on the same Simulator: it is the more specific of the two, and a
/// pinned Simulator is only leased on purpose, with `--device`.
@Test func aLeaseOnAPinnedSimulatorSaysWhoHasIt() {
    let temp = TempDir()
    temp.makeFile(".config/simlease/pinned", contents: signedIn + "\n")
    temp.makeFile("simlease/leases/\(signedIn).json", contents: leaseJSON(
        udid: signedIn, deviceName: "qa-01", owner: "login-test"))

    #expect(read(temp).definiteReason(forSimulator: signedIn)
        == .leasedInSimLease(owner: "login-test"))
}

/// An emulator lease is keyed by its **port** and names the AVD in `deviceName`. The AVD is
/// what `avdmanager delete` would take, so that is what is protected.
@Test func anEmulatorLeaseProtectsTheAVDItRunsAnInstanceOf() {
    let temp = TempDir()
    temp.makeFile("simlease/leases/emulator-5560.json", contents: leaseJSON(
        udid: "emulator-5560", deviceName: "work_avd", owner: "ui-check"))

    let state = read(temp)
    #expect(state.leases.first?.isEmulator == true)
    #expect(state.definiteReason(forAVD: "work_avd") == .leasedInSimLease(owner: "ui-check"))
    // Without case, because on a case-insensitive disk those are one AVD.
    #expect(state.definiteReason(forAVD: "Work_AVD") == .leasedInSimLease(owner: "ui-check"))
    // The over-fix guard: another AVD stays deletable, and so does a Simulator that happens
    // to share the serial's name.
    #expect(state.reason(forAVD: "sample_emulator") == nil)
    #expect(state.reason(forSimulator: "emulator-5560") == nil)
    #expect(!state.emulatorsInDoubt)
}

/// Read-only instances let several leases run one AVD at once. Every owner is named, sorted,
/// so the row does not reword itself between scans.
@Test func twoLeasesOnOneAVDNameBothOwners() {
    let temp = TempDir()
    temp.makeFile("simlease/leases/emulator-5562.json", contents: leaseJSON(
        udid: "emulator-5562", deviceName: "work_avd", owner: "zeta-agent"))
    temp.makeFile("simlease/leases/emulator-5560.json", contents: leaseJSON(
        udid: "emulator-5560", deviceName: "work_avd", owner: "alpha-agent"))

    #expect(read(temp).definiteReason(forAVD: "work_avd")
        == .leasedInSimLease(owner: "alpha-agent, zeta-agent"))
}

/// A lease file that is not JSON is **still a lease**: it exists, so the guard that wrote it
/// may be holding the device, and its name — SimLease names every file `<udid>.json` — says
/// which device that is. Only the owner is lost.
@Test func aSimulatorLeaseThatIsNotJSONStillProtectsTheSimulatorItIsNamedFor() {
    let temp = TempDir()
    temp.makeFile("simlease/leases/\(captureTablet).json", contents: "{\"udid\": \"9A4C2E70-")

    let state = read(temp)
    #expect(state.definiteReason(forSimulator: captureTablet) == .leasedInSimLease(owner: nil))
    #expect(ProtectionReason.leasedInSimLease(owner: nil).description == "leased in SimLease")
    // A Simulator's file names its Simulator, so nothing else is in doubt.
    #expect(!state.simulatorsInDoubt)
    #expect(!state.emulatorsInDoubt)
}

/// An emulator lease that cannot be read is keyed by a port, and a port says nothing about
/// which AVD is running there. Every AVD is in doubt, and none of them may go.
@Test func anEmulatorLeaseThatIsNotJSONPutsEveryAVDInDoubt() {
    let temp = TempDir()
    temp.makeFile("simlease/leases/emulator-5560.json", contents: "not json at all")

    let state = read(temp)
    #expect(state.emulatorsInDoubt)
    #expect(!state.simulatorsInDoubt)
    #expect(state.definiteReason(forAVD: "work_avd") == nil)
    #expect(state.reason(forAVD: "work_avd") == .simLeaseUnreadable)
    #expect(state.reason(forAVD: "sample_emulator") == .simLeaseUnreadable)
    #expect(ProtectionReason.simLeaseUnreadable.description == "SimLease state could not be read")
}

@Test func anEmulatorLeaseWithNoAVDNamePutsEveryAVDInDoubt() {
    let temp = TempDir()
    temp.makeFile("simlease/leases/emulator-5564.json",
                  contents: #"{"udid": "emulator-5564", "owner": "someone"}"#)

    let state = read(temp)
    #expect(state.emulatorsInDoubt)
    #expect(state.reason(forAVD: "work_avd") == .simLeaseUnreadable)
}

/// A lease directory that exists and cannot be listed may hold a lease on anything.
@Test func aLeaseDirectoryThatCannotBeListedPutsEveryDeviceInDoubt() {
    let temp = TempDir()
    // A file where the directory should be.
    temp.makeFile("simlease/leases", contents: "")

    let state = read(temp)
    #expect(state.simulatorsInDoubt)
    #expect(state.emulatorsInDoubt)
}

/// SimLease's guard ends a lease the second its expiry passes and removes the file on the
/// way out, so a file whose expiry is long gone is one a crashed guard left behind — and
/// protecting a device forever on the strength of it would be its own kind of wrong.
@Test func aLeaseLongPastItsExpiryIsOverAndOneJustPastItStillCounts() {
    let temp = TempDir()
    temp.makeFile("simlease/leases/\(signedIn).json", contents: leaseJSON(
        udid: signedIn, deviceName: "qa-01", owner: "crashed-guard",
        expiresAt: now.addingTimeInterval(-3_600)))
    temp.makeFile("simlease/leases/emulator-5560.json", contents: leaseJSON(
        udid: "emulator-5560", deviceName: "work_avd", owner: "shutting-down",
        expiresAt: now.addingTimeInterval(-30)))

    let state = read(temp)
    #expect(state.definiteReason(forSimulator: signedIn) == nil)
    // Thirty seconds past: the guard may still be stopping the emulator, so it counts.
    #expect(state.definiteReason(forAVD: "work_avd") == .leasedInSimLease(owner: "shutting-down"))
}

/// No expiry is not an expired lease. The doubt goes the way that keeps the device.
@Test func aLeaseWithNoExpiryIsReadAsStillRunning() {
    let temp = TempDir()
    temp.makeFile("simlease/leases/\(signedIn).json",
                  contents: #"{"udid": "\#(signedIn)", "owner": "old-schema"}"#)

    #expect(read(temp).definiteReason(forSimulator: signedIn)
        == .leasedInSimLease(owner: "old-schema"))
}

/// SimLease writes every file through a temporary name — `<udid>.json.tmp.<pid>`,
/// `.renew.<pid>`, `.booted.<pid>` — and renames it into place. Those are never leases.
@Test func temporaryFilesAndAnythingNotJSONAreNotLeases() {
    let temp = TempDir()
    temp.makeFile("simlease/leases/\(signedIn).json.tmp.4242", contents: "{")
    temp.makeFile("simlease/leases/emulator-5560.json.renew.4243", contents: "{")
    temp.makeFile("simlease/leases/README", contents: "hello")

    #expect(read(temp) == .empty)
}

// MARK: - where SimLease keeps things

/// A Mac app started from Finder has no shell variables at all. What it reads then is the
/// per-user temporary directory — which launchd gives every process of the user as
/// `TMPDIR`, and so is where every agent's `simlease` keeps its leases — and `/tmp`, for a
/// shell with no `TMPDIR`.
@Test func withNoVariablesTheStandardPlacesAreTheUserTemporaryDirectoryAndTmp() {
    let reader = SimLeaseReader.standard(
        home: "/Users/tester", environment: [:],
        userTemporaryDirectory: "/var/folders/cb/xyz/T/")

    #expect(reader.pinnedFiles == ["/Users/tester/.config/simlease/pinned"])
    #expect(reader.leaseDirectories == [
        "/var/folders/cb/xyz/T/simlease/leases", "/tmp/simlease/leases",
    ])
}

/// Every variable the script honours is honoured here, and **added** to the defaults rather
/// than replacing them: the agent that took a lease had its own environment, not this
/// app's, so a place is read whenever any process might have used it.
@Test func everyVariableTheScriptHonoursAddsAPlaceWithoutRemovingTheDefaults() {
    let reader = SimLeaseReader.standard(
        home: "/Users/tester",
        environment: [
            "SIMLEASE_PINNED_FILE": "/etc/simlease/pinned",
            "SIMLEASE_CONFIG_DIR": "/Users/tester/simlease-config",
            "XDG_CONFIG_HOME": "/Users/tester/xdg",
            "SIMLEASE_DIR": "/Volumes/Fast/simlease",
            // With the trailing slash macOS really puts on it, and the same directory as
            // the per-user one, so it must not be read twice.
            "TMPDIR": "/var/folders/cb/xyz/T/",
        ],
        userTemporaryDirectory: "/var/folders/cb/xyz/T")

    #expect(reader.pinnedFiles == [
        "/etc/simlease/pinned",
        "/Users/tester/simlease-config/pinned",
        "/Users/tester/xdg/simlease/pinned",
        "/Users/tester/.config/simlease/pinned",
    ])
    #expect(reader.leaseDirectories == [
        "/Volumes/Fast/simlease/leases",
        "/var/folders/cb/xyz/T/simlease/leases",
        "/tmp/simlease/leases",
    ])
}

/// An empty variable is unset, as `${VAR:-default}` reads it in the script.
@Test func anEmptyVariableIsReadAsUnset() {
    let reader = SimLeaseReader.standard(
        home: "/Users/tester",
        environment: ["SIMLEASE_DIR": "", "SIMLEASE_CONFIG_DIR": "", "TMPDIR": ""],
        userTemporaryDirectory: nil)

    #expect(reader.pinnedFiles == ["/Users/tester/.config/simlease/pinned"])
    #expect(reader.leaseDirectories == ["/tmp/simlease/leases"])
}

@Test func thePerUserTemporaryDirectoryIsAnAbsolutePath() throws {
    let path = try #require(SimLeaseReader.darwinUserTemporaryDirectory())
    #expect(path.hasPrefix("/"))
}
