import Foundation

/// One SimLease lease, as its metadata file describes it.
///
/// SimLease writes one JSON file per leased device, named after the device and written with
/// a temporary file and a rename, so a reader never sees half of one. The same file serves
/// both platforms: for an emulator `udid` is the instance's serial, `emulator-5560`, and
/// `deviceName` is **the AVD** the instance runs.
public struct SimLeaseLease: Sendable, Equatable {
    /// The Simulator's UDID, or `emulator-<port>` for an emulator. From the file's `udid`,
    /// or from the file's own name when the file could not be read — SimLease names every
    /// metadata file `<udid>.json`, so the name is the one thing a broken file still says.
    public let deviceID: String
    /// The Simulator's name, or the AVD for an emulator. `nil` when the file did not say.
    public let deviceName: String?
    /// The agent or task that took the lease, `acquire --owner`. `nil` when not readable.
    public let owner: String?
    /// When the lease runs out. `nil` when not readable, which is read as still running.
    public let expiresAt: Date?

    /// Public so another module can build one; a `struct`'s memberwise initialiser is not
    /// visible outside its own module.
    public init(deviceID: String, deviceName: String?, owner: String?, expiresAt: Date?) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.owner = owner
        self.expiresAt = expiresAt
    }

    /// SimLease's own test, `is_android_id`: an emulator lease is keyed by its serial.
    public var isEmulator: Bool { deviceID.hasPrefix("emulator-") }
}

/// What SimLease says about this Mac's devices: the Simulators pinned in it and the leases
/// held right now.
///
/// SimLease hands Simulators and emulators to coding agents one at a time, and it knows two
/// things that decide whether a device may be deleted. This app knew neither of them.
///
/// 1. **Pinned Simulators.** `~/.config/simlease/pinned` lists Simulators whose state is
///    worth keeping — one signed in to a test account, two holding exactly the ten clips a
///    capture pipeline was seeded with. Nothing about them is recent: they are kept
///    *because* nobody boots them. Left idle past `deviceRecentUseDays`, every rule this
///    app had offered them to `simctl delete`, which takes the sign-in and the seeded
///    library with it. No Trash, no undo.
/// 2. **Active leases.** A device an agent is using right now. An emulator lease runs a
///    read-only *instance* of an AVD, so the AVD's own files show no sign of use at all.
///
/// Both become hard protection, like the pin in settings: never ticked, refused by the
/// executor, and the reason printed on the row.
///
/// **Case does not matter for a UDID.** simctl prints them upper case and SimLease compares
/// them exactly, so a pin written in lower case is one SimLease itself ignores. It is still
/// the user saying "keep this", and honouring it costs a device that stays.
public struct SimLeaseState: Sendable, Equatable {
    /// Every UDID in the pinned files, upper-cased.
    public let pinnedUDIDs: Set<String>
    /// The leases still running, in file-name order.
    public let leases: [SimLeaseLease]
    /// SimLease has something on disk about Simulators that could not be read — a pinned
    /// file, or a lease directory — so no Simulator can be ruled out.
    public let simulatorsInDoubt: Bool
    /// The same for emulators: an emulator lease that does not say which AVD it runs, or a
    /// lease directory that could not be listed. Any AVD might be the one in use.
    public let emulatorsInDoubt: Bool

    public init(pinnedUDIDs: Set<String> = [], leases: [SimLeaseLease] = [],
                simulatorsInDoubt: Bool = false, emulatorsInDoubt: Bool = false) {
        self.pinnedUDIDs = Set(pinnedUDIDs.map { $0.uppercased() })
        self.leases = leases
        self.simulatorsInDoubt = simulatorsInDoubt
        self.emulatorsInDoubt = emulatorsInDoubt
    }

    /// No SimLease on this Mac, or nothing in it.
    public static let empty = SimLeaseState()

    /// Why SimLease holds this Simulator, when it knows: a lease first, then a pin.
    ///
    /// A lease wins because it is the more specific of the two — it names who has the
    /// device — and a pinned Simulator is only ever leased on purpose, by `--device`.
    public func definiteReason(forSimulator udid: String) -> ProtectionReason? {
        let wanted = udid.uppercased()
        let holders = leases.filter { !$0.isEmulator && $0.deviceID.uppercased() == wanted }
        if !holders.isEmpty { return .leasedInSimLease(owner: Self.owners(of: holders)) }
        return pinnedUDIDs.contains(wanted) ? .pinnedInSimLease : nil
    }

    /// Why SimLease holds this AVD, when it knows: one or more leases running an instance.
    ///
    /// Compared without case. `acquire --avd` only accepts a name `emulator -list-avds`
    /// printed, so the two agree today; on a case-insensitive disk `Pixel_8` and `pixel_8`
    /// are one AVD anyway, and the cost of reading them as one is an emulator that stays.
    public func definiteReason(forAVD name: String) -> ProtectionReason? {
        let wanted = name.lowercased()
        let holders = leases.filter { $0.isEmulator && $0.deviceName?.lowercased() == wanted }
        return holders.isEmpty ? nil : .leasedInSimLease(owner: Self.owners(of: holders))
    }

    /// The reason to refuse deleting this Simulator, doubt included. What the executor asks.
    public func reason(forSimulator udid: String) -> ProtectionReason? {
        definiteReason(forSimulator: udid) ?? (simulatorsInDoubt ? .simLeaseUnreadable : nil)
    }

    /// The reason to refuse deleting this AVD, doubt included. What the executor asks.
    public func reason(forAVD name: String) -> ProtectionReason? {
        definiteReason(forAVD: name) ?? (emulatorsInDoubt ? .simLeaseUnreadable : nil)
    }

    /// Several read-only instances of one AVD can run at once, one per lease, so an AVD can
    /// have several owners. Sorted and de-duplicated so the text does not move between scans.
    private static func owners(of leases: [SimLeaseLease]) -> String? {
        let names = Set(leases.compactMap(\.owner)).sorted()
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
}

/// Reads SimLease's files directly, and never runs `simlease`.
///
/// **Not `simlease status --json`**, although it carries the same leases, for three reasons
/// that each would have been enough:
///
/// 1. It is not read-only. `status` clears away leases whose guard has died, and clearing
///    one **shuts down the device** when SimLease booted it — a scan must not stop an
///    emulator.
/// 2. It is slow. It asks simctl, `memory_pressure` and adb before it answers.
/// 3. It may not be found. A Mac app started from Finder has no `~/.local/bin` on its PATH,
///    and the CLI needs `jq`.
///
/// The files are what the CLI reads too: `SIMLEASE_DIR` (default `${TMPDIR}/simlease`) holds
/// `leases/<udid>.json`, one per lease, and `~/.config/simlease/pinned` holds the pins. A
/// Mac without SimLease has neither, and that reads as nothing held.
///
/// **When unsure, protect.** Every failure here is one of two kinds. A place that does not
/// exist is an ordinary answer: nothing is there. Something that exists and cannot be read
/// is a doubt, and a doubt protects every device on that platform — see
/// `ProtectionReason.simLeaseUnreadable`. Nothing here throws.
// @unchecked because of the stored FileManager — see Global Constraints.
public struct SimLeaseReader: @unchecked Sendable {
    /// How long past its expiry a lease file still counts.
    ///
    /// SimLease's guard ends a lease within a second of its expiry and removes the file on the
    /// way out, and `exec` renews long before that, so an expired file is one a crashed guard
    /// left behind. The five minutes are for the guard's own exit: it stops the emulator
    /// before it removes the file, and that can take twenty seconds.
    static let expiryGrace: TimeInterval = 300

    /// Pinned files to read, each one optional. Their UDIDs are added together.
    public let pinnedFiles: [String]
    /// `leases` directories to read, each one optional. Their leases are added together.
    public let leaseDirectories: [String]
    private let fileManager: FileManager

    /// Explicit paths, which is what every test passes: temporary directories, never the real
    /// `~/.config` or `$TMPDIR`.
    public init(pinnedFiles: [String], leaseDirectories: [String],
                fileManager: FileManager = .default) {
        self.pinnedFiles = pinnedFiles
        self.leaseDirectories = leaseDirectories
        self.fileManager = fileManager
    }

    /// The places SimLease would use on this Mac, **all of them at once**.
    ///
    /// SimLease picks one directory from its environment, and the environment of the agent
    /// that took a lease is not this app's: a Mac app started from Finder has no shell
    /// profile, so a `SIMLEASE_DIR` exported there is invisible here. What this can do is
    /// read every place SimLease's own defaults can land — the variables, if this process has
    /// them, the per-user temporary directory macOS gives every login process as `TMPDIR`,
    /// and `/tmp` for a shell with no `TMPDIR` at all — and add up what it finds. Reading one
    /// place too many costs a directory listing; reading one too few costs a device.
    ///
    /// The pinned file follows the script exactly: `SIMLEASE_PINNED_FILE`, else
    /// `SIMLEASE_CONFIG_DIR`, else `XDG_CONFIG_HOME`, else `~/.config` — and here the default
    /// is read as well, for the same reason.
    public static func standard(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userTemporaryDirectory: String? = SimLeaseReader.darwinUserTemporaryDirectory(),
        fileManager: FileManager = .default
    ) -> SimLeaseReader {
        func value(_ key: String) -> String? {
            environment[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        func joined(_ base: String, _ relative: String) -> String {
            (base as NSString).appendingPathComponent(relative)
        }

        var pinned: [String] = []
        if let file = value("SIMLEASE_PINNED_FILE") { pinned.append(file) }
        if let config = value("SIMLEASE_CONFIG_DIR") { pinned.append(joined(config, "pinned")) }
        if let xdg = value("XDG_CONFIG_HOME") { pinned.append(joined(xdg, "simlease/pinned")) }
        pinned.append(joined(home, ".config/simlease/pinned"))

        var roots: [String] = []
        if let root = value("SIMLEASE_DIR") { roots.append(root) }
        if let temporary = value("TMPDIR") { roots.append(joined(temporary, "simlease")) }
        if let temporary = userTemporaryDirectory { roots.append(joined(temporary, "simlease")) }
        roots.append("/tmp/simlease")

        return SimLeaseReader(
            pinnedFiles: unique(pinned),
            leaseDirectories: unique(roots.map { joined($0, "leases") }),
            fileManager: fileManager)
    }

    /// The per-user temporary directory, `/var/folders/…/T/`, which is what launchd sets as
    /// `TMPDIR` for every process of this user and so where SimLease's leases live by default.
    public static func darwinUserTemporaryDirectory() -> String? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return path.isEmpty ? nil : path
    }

    /// Everything SimLease says, as of `now`.
    public func read(now: Date) -> SimLeaseState {
        var pinned: Set<String> = []
        var simulatorsInDoubt = false
        var emulatorsInDoubt = false

        for path in pinnedFiles where fileManager.fileExists(atPath: path) {
            // There, and unreadable — no permission, or a directory where the file should be.
            // Which Simulators it pins is unknown, so none of them may go.
            guard let data = fileManager.contents(atPath: path) else {
                simulatorsInDoubt = true
                continue
            }
            // Decoded leniently. A stray non-UTF-8 byte in a comment must not turn a readable
            // list of UDIDs into a doubt about every Simulator on the Mac.
            pinned.formUnion(Self.pinnedUDIDs(inPinnedFile: String(decoding: data, as: UTF8.self)))
        }

        var leases: [SimLeaseLease] = []
        for directory in leaseDirectories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) else {
                continue
            }
            // There and not listable: some lease may be in it, on either platform.
            guard isDirectory.boolValue,
                  let names = try? fileManager.contentsOfDirectory(atPath: directory)
            else {
                simulatorsInDoubt = true
                emulatorsInDoubt = true
                continue
            }
            // Sorted, because `contentsOfDirectory` promises no order and an owner list built
            // from it would reorder between scans.
            for name in names.sorted() {
                let path = (directory as NSString).appendingPathComponent(name)
                guard let lease = Self.lease(fileNamed: name,
                                             contents: fileManager.contents(atPath: path)),
                      Self.isActive(lease, at: now)
                else { continue }
                // An emulator lease is keyed by its port, not its AVD, so one that does not
                // name the AVD could be running any of them.
                if lease.isEmulator && lease.deviceName == nil { emulatorsInDoubt = true }
                leases.append(lease)
            }
        }

        return SimLeaseState(pinnedUDIDs: pinned, leases: leases,
                             simulatorsInDoubt: simulatorsInDoubt,
                             emulatorsInDoubt: emulatorsInDoubt)
    }

    // MARK: parsing

    /// The UDIDs in a pinned file, upper-cased. The same rule as the script's `is_pinned`:
    /// everything from a `#` to the end of the line goes, then **every** space and tab, and
    /// what is left, if anything, is a UDID.
    ///
    /// The real file puts a comment after each UDID —
    /// `5D2E8A10-…-1C6B0E2D4A71  # qa-01: signed in to the test account` — which is why the
    /// comment is cut before the whitespace. Split on any line ending, so a CRLF file's `\r`
    /// is not glued to the last UDID on each line.
    static func pinnedUDIDs(inPinnedFile contents: String) -> Set<String> {
        var result: Set<String> = []
        for line in contents.split(whereSeparator: \.isNewline) {
            let uncommented = line.firstIndex(of: "#").map { line[..<$0] } ?? line
            let udid = String(uncommented.filter { !$0.isWhitespace }).uppercased()
            if !udid.isEmpty { result.insert(udid) }
        }
        return result
    }

    /// One lease from one directory entry, or `nil` when the entry is not a lease file.
    ///
    /// Only `*.json`: SimLease's temporary files are `<udid>.json.tmp.<pid>` and friends, and
    /// are never read. A `.json` whose contents are not a JSON object is **still a lease** —
    /// the file exists, so the guard that wrote it may be running — and its name says which
    /// device it is for. Only the owner and the expiry are lost, and a lease with no expiry
    /// is read as running.
    static func lease(fileNamed name: String, contents: Data?) -> SimLeaseLease? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = String(name.dropLast(".json".count))
        guard !stem.isEmpty, !stem.hasPrefix(".") else { return nil }

        let object = contents.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            as? [String: Any]
        func text(_ key: String) -> String? {
            (object?[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return SimLeaseLease(
            deviceID: text("udid") ?? stem,
            deviceName: text("deviceName"),
            owner: text("owner"),
            expiresAt: (object?["expiresAtEpoch"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) })
    }

    /// Whether a lease still counts at `now`. No expiry at all counts: the doubt goes the way
    /// that keeps the device.
    static func isActive(_ lease: SimLeaseLease, at now: Date) -> Bool {
        guard let expiresAt = lease.expiresAt else { return true }
        return now < expiresAt.addingTimeInterval(expiryGrace)
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert(($0 as NSString).standardizingPath).inserted }
    }
}
