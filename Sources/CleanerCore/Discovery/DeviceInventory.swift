import Foundation

public struct SimulatorDevice: Sendable, Equatable {
    public let udid: String
    public let name: String
    public let runtimeIdentifier: String
    /// Booted right now. `ProtectionResolver` refuses to offer such a device and
    /// `Executor` refuses to delete one — see `ProtectionReason.bootedDevice`.
    public let isBooted: Bool
    public let sizeBytes: Int64
    public let lastBootedAt: Date?

    /// Public so the menu bar app target can build one; a `struct`'s memberwise
    /// initialiser is not visible outside its module.
    public init(udid: String, name: String, runtimeIdentifier: String, isBooted: Bool,
                sizeBytes: Int64, lastBootedAt: Date?) {
        self.udid = udid
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.isBooted = isBooted
        self.sizeBytes = sizeBytes
        self.lastBootedAt = lastBootedAt
    }
}

/// One runtime **disk image**, as `xcrun simctl runtime list -j` reports it.
///
/// On current Xcode a simulator runtime is not a folder somebody installed: it is a disk
/// image the system serves, mounted at `/Library/Developer/CoreSimulator/Volumes/iOS_<build>`,
/// and the `.simruntime` bundle `simctl list runtimes --json` reports sits **inside** that
/// mounted volume. Two things follow, and the app had both wrong:
///
/// 1. `simctl runtime delete` wants **this** `identifier` — a UUID — or the build number.
///    Handed the runtime identifier instead it answers "No runtime disk images or bundles
///    found matching 'com.apple.CoreSimulator.SimRuntime.iOS-26-5'" and deletes nothing,
///    which is what a user got after pressing "Delete 17.3 GB for good".
/// 2. `sizeBytes` is the image file: the bytes that occupy the disk and the bytes deleting
///    it gives back. `du` over the bundle measures the unpacked contents of the mounted
///    volume instead, and reported 17.3 GB for an 8.49 GB image.
public struct SimulatorRuntimeImage: Sendable, Equatable {
    /// The UUID `simctl runtime delete` takes. **Never** the runtime identifier.
    public let identifier: String
    /// The OS build in the image, e.g. `23F77`. Half of what matches an image to a
    /// runtime: two builds of one version can be installed side by side, each with its own
    /// image, and the runtime identifier — which is derived from the version — is the same
    /// string for both.
    public let build: String
    /// What the image file occupies. 0 when simctl did not report it.
    public let sizeBytes: Int64
    /// What simctl says about removing it. False for a runtime the system will not let go,
    /// and a row offering one is a button that fails after the click.
    public let deletable: Bool
    /// `Ready`, `Unusable`, … Carried verbatim, because this is simctl's vocabulary and
    /// not something this app should be paraphrasing.
    public let state: String

    /// Public so another module can build one; a `struct`'s memberwise initialiser is not
    /// visible outside its own module.
    public init(identifier: String, build: String, sizeBytes: Int64,
                deletable: Bool, state: String) {
        self.identifier = identifier
        self.build = build
        self.sizeBytes = sizeBytes
        self.deletable = deletable
        self.state = state
    }
}

public struct SimulatorRuntime: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let version: String
    public let buildVersion: String
    /// Where the runtime is installed. Needed because a **bundle** runtime has no reported
    /// size and must be measured with du. Empty when simctl does not report it.
    public let bundlePath: String
    /// The disk image or images behind this runtime, matched on runtime identifier **and**
    /// build — see `SimulatorRuntimeImage`.
    ///
    /// Empty is an ordinary answer, not a failure: a legacy bundle runtime has no image,
    /// and neither has anything on an Xcode whose `simctl runtime list -j` could not be
    /// read. Everything about such a runtime behaves exactly as it did before images were
    /// read at all — `du` over the bundle, and `simctl runtime delete <runtime identifier>`.
    public let images: [SimulatorRuntimeImage]

    /// `images` defaults to empty so every existing call site compiles unchanged and means
    /// what it meant: a runtime nothing knows an image for.
    public init(identifier: String, name: String, version: String,
                buildVersion: String, bundlePath: String,
                images: [SimulatorRuntimeImage] = []) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.buildVersion = buildVersion
        self.bundlePath = bundlePath
        self.images = images
    }

    /// What deleting this runtime really gives back, when the disk image can say.
    ///
    /// `nil` means "measure `bundlePath` with du", which is the only answer available for a
    /// bundle runtime and the answer this app gave every runtime until now.
    ///
    /// Summed rather than "the first image", because two builds of one version are two
    /// files on disk. A total of zero reads as `nil` rather than as a 0-byte row: an image
    /// whose `sizeBytes` simctl did not report is not an image that is free, and `du` over
    /// the bundle is a worse number than the real one but a far better one than nothing.
    public var imageSizeBytes: Int64? {
        let total = images.reduce(0) { $0 + $1.sizeBytes }
        return total > 0 ? total : nil
    }

    /// Whether every image behind this runtime is one simctl will delete.
    ///
    /// True when there are no images, which is the bundle-runtime case: nothing is claiming
    /// otherwise, so nothing changes. `false` has to be simctl's own claim.
    public var everyImageIsDeletable: Bool { images.allSatisfy(\.deletable) }
}

public struct AndroidAVD: Sendable, Equatable {
    public let name: String
    public let directoryPath: String
    public let lastUsed: Date?
    /// Relative to the Android SDK root, e.g. `system-images/android-34/google_apis/arm64-v8a`.
    public let systemImageRelativePath: String?

    public init(name: String, directoryPath: String, lastUsed: Date?,
                systemImageRelativePath: String?) {
        self.name = name
        self.directoryPath = directoryPath
        self.lastUsed = lastUsed
        self.systemImageRelativePath = systemImageRelativePath
    }
}

public struct DeviceInventory: Sendable, Equatable {
    public let simulators: [SimulatorDevice]
    public let runtimes: [SimulatorRuntime]
    public let avds: [AndroidAVD]

    public init(simulators: [SimulatorDevice], runtimes: [SimulatorRuntime], avds: [AndroidAVD]) {
        self.simulators = simulators
        self.runtimes = runtimes
        self.avds = avds
    }

    public static let empty = DeviceInventory(simulators: [], runtimes: [], avds: [])
}

// @unchecked because of the stored FileManager — see Global Constraints.
public struct DeviceInventoryLoader: @unchecked Sendable {
    private let runner: any ProcessRunner
    private let fileManager: FileManager
    private let home: String
    private let androidSDKPath: String

    public init(
        runner: any ProcessRunner,
        fileManager: FileManager = .default,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        androidSDKPath: String? = nil
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.home = home
        self.androidSDKPath = androidSDKPath
            ?? (home as NSString).appendingPathComponent("Library/Android/sdk")
    }

    public func load() -> DeviceInventory {
        DeviceInventory(
            simulators: loadSimulators(),
            runtimes: loadRuntimes(),
            avds: loadAVDs())
    }

    // MARK: simulators

    private func loadSimulators() -> [SimulatorDevice] {
        guard let json = runJSON(["simctl", "list", "devices", "--json"]),
              let byRuntime = json["devices"] as? [String: [[String: Any]]]
        else { return [] }

        let formatter = ISO8601DateFormatter()
        var devices: [SimulatorDevice] = []
        for (runtimeIdentifier, entries) in byRuntime {
            for entry in entries {
                guard let udid = entry["udid"] as? String,
                      let name = entry["name"] as? String else { continue }
                let lastBooted = (entry["lastBootedAt"] as? String).flatMap(formatter.date(from:))
                devices.append(SimulatorDevice(
                    udid: udid,
                    name: name,
                    runtimeIdentifier: runtimeIdentifier,
                    isBooted: (entry["state"] as? String) == "Booted",
                    sizeBytes: (entry["dataPathSize"] as? NSNumber)?.int64Value ?? 0,
                    lastBootedAt: lastBooted))
            }
        }
        return devices.sorted { $0.name < $1.name }
    }

    private func loadRuntimes() -> [SimulatorRuntime] {
        guard let json = runJSON(["simctl", "list", "runtimes", "--json"]),
              let entries = json["runtimes"] as? [[String: Any]]
        else { return [] }

        let images = loadRuntimeImages()
        let runtimes = entries.compactMap { entry -> SimulatorRuntime? in
            guard let identifier = entry["identifier"] as? String,
                  let version = entry["version"] as? String else { return nil }
            let build = (entry["buildversion"] as? String) ?? ""
            return SimulatorRuntime(
                identifier: identifier,
                name: (entry["name"] as? String) ?? version,
                version: version,
                buildVersion: build,
                bundlePath: (entry["bundlePath"] as? String) ?? "",
                // **Both halves of the key, never the runtime identifier alone.** That
                // identifier is derived from the version, so two builds of one version share
                // it, and attaching one build's image to the other runtime would delete a
                // several-gigabyte download nobody asked about. A build missing on either
                // side matches nothing, which lands the runtime in the `du`-and-runtime-
                // identifier fallback — where every runtime was before images were read.
                images: build.isEmpty ? [] : images
                    .filter { $0.runtimeIdentifier == identifier && $0.image.build == build }
                    .map(\.image))
        }
        return runtimes.sorted { Self.isNewer($0.version, than: $1.version) }
    }

    /// One parsed image and the runtime it names.
    ///
    /// Private because the pairing is gone by the time the inventory exists: a matched
    /// image hangs off its `SimulatorRuntime`, and an image matching no installed runtime
    /// is dropped rather than carried somewhere nothing would look at it.
    private struct ImageEntry {
        let runtimeIdentifier: String
        let image: SimulatorRuntimeImage
    }

    /// The disk images `xcrun simctl runtime list -j` reports.
    ///
    /// **No answer is an ordinary outcome, not an error.** `simctl runtime list` is not on
    /// every Xcode, and where it is missing there are no images: each runtime then falls
    /// back to `du` over its bundle and to `simctl runtime delete <runtime identifier>`,
    /// which is precisely what this app did before. So a command that fails, an empty
    /// stdout and a document that is not the shape expected all answer the same way —
    /// nothing — and nothing else about the scan changes.
    ///
    /// The document is a JSON **object keyed by image UUID**, not an array:
    /// `{"09A925DA-…": {"build": "23F77", "runtimeIdentifier": "…SimRuntime.iOS-26-5", …}}`.
    /// Every field is read defensively, and the two that decide something are required: an
    /// image with no `runtimeIdentifier` cannot be matched to a runtime and must not be
    /// attached to one, and an image with no identifier has nothing to hand
    /// `simctl runtime delete`.
    private func loadRuntimeImages() -> [ImageEntry] {
        guard let json = runJSON(["simctl", "runtime", "list", "-j"]) else { return [] }

        let entries = json.compactMap { key, value -> ImageEntry? in
            guard let fields = value as? [String: Any],
                  let runtimeIdentifier = fields["runtimeIdentifier"] as? String,
                  !runtimeIdentifier.isEmpty
            else { return nil }
            // The key **is** the image UUID and `identifier` repeats it. The field is
            // preferred because it is the one simctl documents; the key is the fallback, so
            // a document carrying only one of the two still yields a deletable image.
            let identifier = (fields["identifier"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 } ?? key
            guard !identifier.isEmpty else { return nil }
            return ImageEntry(
                runtimeIdentifier: runtimeIdentifier,
                image: SimulatorRuntimeImage(
                    identifier: identifier,
                    build: (fields["build"] as? String) ?? "",
                    sizeBytes: (fields["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                    // Absent reads as deletable, which is what the app assumed of every
                    // runtime before it asked. `false` has to be simctl's own claim: the
                    // other default would protect every runtime on any Xcode whose document
                    // lacks the key, and the scanner would stop offering the biggest thing
                    // it finds on the strength of a missing field.
                    deletable: (fields["deletable"] as? Bool) ?? true,
                    state: (fields["state"] as? String) ?? ""))
        }
        // Sorted for the same reason `loadSimulators` sorts: a dictionary hands its pairs
        // back in no particular order, and this order is the order the executor deletes in.
        return entries.sorted { $0.image.identifier < $1.image.identifier }
    }

    /// Compares dotted version strings numerically, so 18.2 sorts below 26.5
    /// and 26.10 sorts above 26.5 — string comparison gets both wrong.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private func runJSON(_ arguments: [String]) -> [String: Any]? {
        guard let result = try? runner.run("/usr/bin/xcrun", arguments), result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    // MARK: AVDs

    private func loadAVDs() -> [AndroidAVD] {
        let avdRoot = (home as NSString).appendingPathComponent(".android/avd")
        guard let entries = try? fileManager.contentsOfDirectory(atPath: avdRoot) else { return [] }

        return entries.compactMap { entry -> AndroidAVD? in
            guard entry.hasSuffix(".avd") else { return nil }
            let name = String(entry.dropLast(4))
            let directory = (avdRoot as NSString).appendingPathComponent(entry)

            return AndroidAVD(
                name: name,
                directoryPath: directory,
                lastUsed: lastUsed(ofAVDAt: directory),
                systemImageRelativePath: systemImage(inConfigAt: directory))
        // Sorted for the same reason `loadSimulators` sorts: `contentsOfDirectory`
        // promises no order, so an unsorted list reshuffles between scans and the tick
        // boxes move under the user's cursor.
        }.sorted { $0.name < $1.name }
    }

    /// The newest modification time among the entries directly inside the `.avd`
    /// directory.
    ///
    /// Not a single pinned filename: `userdata-qemu.img` records when the AVD was
    /// created, not when it ran, because the emulator writes to the copy-on-write
    /// overlay `userdata-qemu.img.qcow2` instead. Pinning that overlay name instead
    /// would repeat the same bug — `emulator-user.ini` and `bootcompleted.ini` are
    /// secondary signals and not every AVD has all three.
    ///
    /// Non-recursive on purpose. That is roughly 22 stat calls per AVD, and it must
    /// never walk `snapshots/`, which is multi-gigabyte.
    ///
    /// The directory's own mtime is deliberately excluded from the maximum and kept
    /// only as a fallback for an empty or unreadable directory. Deleting files inside
    /// an AVD bumps the directory mtime, and deletion is cleanup, not use. Counting it
    /// would overstate one device's recency, which is what gets a genuinely-used
    /// device deleted under a keep-the-newest rule.
    private func lastUsed(ofAVDAt directory: String) -> Date? {
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        let dates = entries.compactMap {
            modificationDate(of: (directory as NSString).appendingPathComponent($0))
        }
        return dates.max() ?? modificationDate(of: directory)
    }

    private func systemImage(inConfigAt directory: String) -> String? {
        let configPath = (directory as NSString).appendingPathComponent("config.ini")
        guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        // Split on the FIRST `=` only, never `split(separator: "=")` — a value may
        // contain one. Real config.ini writes `image.sysdir.1 = value` with a space
        // either side; the sibling <name>.ini pointer files use `key=value` with no
        // spaces. Trimming both halves handles both conventions. `.whitespacesAndNewlines`
        // rather than `.whitespaces`, because the latter is space and tab only and would
        // leave a trailing `\r` on a CRLF file, defeating the `hasSuffix("/")` strip.
        for line in contents.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines) == "image.sysdir.1"
            else { continue }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed = value.hasSuffix("/") ? String(value.dropLast()) : value
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func modificationDate(of path: String) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
