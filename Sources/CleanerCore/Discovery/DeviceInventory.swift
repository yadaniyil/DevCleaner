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

public struct SimulatorRuntime: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let version: String
    public let buildVersion: String
    /// Where the runtime is installed. Needed because runtimes have no reported
    /// size and must be measured with du. Empty when simctl does not report it.
    public let bundlePath: String

    public init(identifier: String, name: String, version: String,
                buildVersion: String, bundlePath: String) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.buildVersion = buildVersion
        self.bundlePath = bundlePath
    }
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

        let runtimes = entries.compactMap { entry -> SimulatorRuntime? in
            guard let identifier = entry["identifier"] as? String,
                  let version = entry["version"] as? String else { return nil }
            return SimulatorRuntime(
                identifier: identifier,
                name: (entry["name"] as? String) ?? version,
                version: version,
                buildVersion: (entry["buildversion"] as? String) ?? "",
                bundlePath: (entry["bundlePath"] as? String) ?? "")
        }
        return runtimes.sorted { Self.isNewer($0.version, than: $1.version) }
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
