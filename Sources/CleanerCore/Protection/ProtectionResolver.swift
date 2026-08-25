import Foundation

public struct ProtectionSet: Sendable, Equatable {
    public let projects: [String: ProtectionReason]
    public let keptSimulatorUDID: String?
    public let keptAVDName: String?
    /// Every device that must not be deleted by default, with the reason to show for
    /// each. Keyed by UDID and by AVD name. A device is a member when it is pinned,
    /// when it is the newest, when it was used within `Settings.deviceRecentUseDays`,
    /// or when its timestamp is within `indistinguishableWindow` of the newest.
    ///
    /// Wider than `keptSimulatorUDID` on purpose. A device cannot be moved to the
    /// Trash, so the default selection must not offer one the user was working with
    /// last week; they can still tick it by hand.
    public let protectedSimulatorUDIDs: [String: ProtectionReason]
    public let protectedAVDNames: [String: ProtectionReason]
    public let flutterVersions: [String: ProtectionReason]
    /// Keyed by the **full distribution directory name** — `gradle-8.14-all`, not
    /// `8.14`. That is the name Gradle gives the folder it creates under
    /// `~/.gradle/wrapper/dists`, so `GradleScanner` compares it directly with no
    /// second parse to drift out of sync.
    ///
    /// A version key was lossy in three ways that all cost the user a download:
    /// `gradle-9.0-rc-1-bin.zip` and `gradle-9.0-bin.zip` both reduced to `9.0`, so a
    /// project on the release candidate protected the final release instead; a nightly
    /// `gradle-8.9-20240611000000+0000-bin.zip` reduced to `8.9` and protected a
    /// distribution nothing used; and `-bin` could not be told from `-all`, which are
    /// two separate downloads that sit side by side.
    public let gradleDistributions: [String: ProtectionReason]
    public let runtimeIdentifiers: [String: ProtectionReason]

    /// Public so the menu bar app target can build one. Without it this type is public
    /// in name only: a `struct` in another module gets no memberwise initialiser, so
    /// every preview and every test double outside this package fails to compile.
    public init(
        projects: [String: ProtectionReason],
        keptSimulatorUDID: String?,
        keptAVDName: String?,
        protectedSimulatorUDIDs: [String: ProtectionReason],
        protectedAVDNames: [String: ProtectionReason],
        flutterVersions: [String: ProtectionReason],
        gradleDistributions: [String: ProtectionReason],
        runtimeIdentifiers: [String: ProtectionReason]
    ) {
        self.projects = projects
        self.keptSimulatorUDID = keptSimulatorUDID
        self.keptAVDName = keptAVDName
        self.protectedSimulatorUDIDs = protectedSimulatorUDIDs
        self.protectedAVDNames = protectedAVDNames
        self.flutterVersions = flutterVersions
        self.gradleDistributions = gradleDistributions
        self.runtimeIdentifiers = runtimeIdentifiers
    }

    public static let empty = ProtectionSet(
        projects: [:], keptSimulatorUDID: nil, keptAVDName: nil,
        protectedSimulatorUDIDs: [:], protectedAVDNames: [:],
        flutterVersions: [:], gradleDistributions: [:], runtimeIdentifiers: [:])
}

// @unchecked because of the stored FileManager — see Global Constraints.
public struct ProtectionResolver: @unchecked Sendable {
    /// Two devices whose timestamps differ by less than this are treated as
    /// indistinguishable. A device cannot be moved to the Trash, so guessing wrong
    /// is permanent; keeping one extra emulator is the cheaper mistake.
    static let indistinguishableWindow: TimeInterval = 2

    private let settings: Settings
    private let fileManager: FileManager

    public init(settings: Settings, fileManager: FileManager = .default) {
        self.settings = settings
        self.fileManager = fileManager
    }

    public func resolve(
        projects: [DiscoveredProject],
        activity: [String: Date],
        devices: DeviceInventory,
        now: Date
    ) -> ProtectionSet {
        let protectedProjects = resolveProjects(projects, activity: activity, now: now)
        let keptSimulator = resolveSimulators(devices.simulators, now: now)
        let keptAVD = resolveAVDs(devices.avds, now: now)

        return ProtectionSet(
            projects: protectedProjects,
            keptSimulatorUDID: keptSimulator.kept,
            keptAVDName: keptAVD.kept,
            protectedSimulatorUDIDs: keptSimulator.protected,
            protectedAVDNames: keptAVD.protected,
            flutterVersions: resolveFlutterVersions(projects),
            gradleDistributions: resolveGradleDistributions(projects, protected: protectedProjects),
            // Every protected simulator, not only the labelled one — see `resolveRuntimes`.
            runtimeIdentifiers: resolveRuntimes(
                devices, keptSimulatorUDID: keptSimulator.kept,
                protectedSimulatorUDIDs: Set(keptSimulator.protected.keys)))
    }

    // MARK: projects

    private func resolveProjects(
        _ projects: [DiscoveredProject], activity: [String: Date], now: Date
    ) -> [String: ProtectionReason] {
        let pinned = Set(settings.pinnedProjectPaths)
        let cutoff = now.addingTimeInterval(-Double(settings.activeThresholdDays) * 86_400)

        var result: [String: ProtectionReason] = [:]
        for project in projects {
            if pinned.contains(project.path) {
                result[project.path] = .pinnedProject
            } else if let last = activity[project.path], last >= cutoff {
                result[project.path] = .recentActivity(days: settings.activeThresholdDays)
            }
        }
        return result
    }

    // MARK: devices

    private func resolveSimulators(
        _ simulators: [SimulatorDevice], now: Date
    ) -> (kept: String?, protected: [String: ProtectionReason]) {
        resolveDevices(
            simulators.map { (id: $0.udid, date: $0.lastBootedAt) },
            pinned: settings.pinnedSimulatorUDID,
            // `isBooted` reaches the resolver here and nowhere else. Mapping it away was
            // how a simulator that is running right now became deletable: `lastBootedAt`
            // is when the boot *started*, so one left running for eight days looks
            // untouched for over a week to every timestamp rule below.
            running: Set(simulators.filter(\.isBooted).map(\.udid)),
            now: now)
    }

    private func resolveAVDs(
        _ avds: [AndroidAVD], now: Date
    ) -> (kept: String?, protected: [String: ProtectionReason]) {
        resolveDevices(
            avds.map { (id: $0.name, date: $0.lastUsed) },
            pinned: settings.pinnedAVDName, now: now)
    }

    /// Decides which devices survive a default clean, and why.
    ///
    /// Five rules, applied as a union rather than as alternatives — protection is
    /// never taken away by another rule matching. `kept` is the single device to
    /// label as the one being kept, and stays what it has always been: the pin when
    /// a pin names a device that exists, otherwise the newest. Being booted does not
    /// change that label; it only adds protection.
    ///
    /// Written lowest-precedence first so that a later rule overwrites the reason an
    /// earlier one recorded for the same device. The stated order is running now, then
    /// pinned, then most recently used, then recently used, then the tie — so it is
    /// applied in reverse here.
    ///
    /// A device with no timestamp can only ever get in by being pinned or by running.
    /// It can never be the newest, can never be recent, and can never tie.
    ///
    /// `running` is empty for emulators. Whether an AVD is running is not in the
    /// inventory at all — it is a question for `adb`, which `Executor.runningEmulators`
    /// asks at the moment of deletion, and an unanswerable `adb` stops the deletion
    /// there. Simulators had no equivalent until this rule.
    private func resolveDevices(
        _ candidates: [(id: String, date: Date?)], pinned: String?,
        running: Set<String> = [], now: Date
    ) -> (kept: String?, protected: [String: ProtectionReason]) {
        let dated = candidates.compactMap { candidate in
            candidate.date.map { (id: candidate.id, date: $0) }
        }
        let winner = Self.newest(dated)
        var protected: [String: ProtectionReason] = [:]

        // 4. Within `indistinguishableWindow` of the newest. Mostly subsumed by rule
        //    3, but it is the only thing standing between a pair of devices that tie
        //    and are both older than `deviceRecentUseDays` — without it one of two
        //    devices the app openly cannot tell apart would be deleted.
        if let winner {
            for candidate in dated
            where abs(candidate.date.timeIntervalSince(winner.date)) < Self.indistinguishableWindow {
                protected[candidate.id] = .mostRecentlyUsedDevice
            }
        }

        // 3. Used within `deviceRecentUseDays`. The day count comes from settings and
        //    is carried into the reason, so the popover text matches the setting.
        let recentCutoff = now.addingTimeInterval(-Double(settings.deviceRecentUseDays) * 86_400)
        for candidate in dated where candidate.date >= recentCutoff {
            protected[candidate.id] = .recentlyUsedDevice(days: settings.deviceRecentUseDays)
        }

        // 2. The newest.
        if let winner { protected[winner.id] = .mostRecentlyUsedDevice }

        // 1. The user's explicit pin, checked against the full device list so that
        //    pinning a never-booted device still keeps it, and a pin naming a device
        //    that no longer exists is ignored rather than reported as kept.
        let livePin = pinned.flatMap { pin in candidates.contains { $0.id == pin } ? pin : nil }
        if let livePin { protected[livePin] = .pinnedDevice }

        // 0. Running right now. Last, so it wins every other reason: it is the only rule
        //    that cannot be out of date, and it is the one the user would be angriest to
        //    see missing from the row. Checked against the full candidate list, like the
        //    pin, so a device with no timestamp is still covered.
        for candidate in candidates where running.contains(candidate.id) {
            protected[candidate.id] = .bootedDevice
        }

        return (livePin ?? winner?.id, protected)
    }

    /// The candidate with the newest timestamp.
    ///
    /// Found with an explicit loop, not `max(by:)`, because ties carry meaning: which
    /// equal element that method returns is not part of its contract, and the answer
    /// here must not depend on it. Only a strictly newer timestamp displaces the
    /// current winner, so a tie keeps the earlier entry in array order — and a tie
    /// inside `indistinguishableWindow` protects both regardless.
    private static func newest(
        _ candidates: [(id: String, date: Date)]
    ) -> (id: String, date: Date)? {
        var winner: (id: String, date: Date)?
        for candidate in candidates {
            if let current = winner, candidate.date <= current.date { continue }
            winner = candidate
        }
        return winner
    }

    /// The runtimes that must survive, keyed by identifier.
    ///
    /// **Every protected simulator's runtime, not only the kept one.** When device
    /// protection widened from "the one most recently used" to "everything used in the
    /// last `deviceRecentUseDays`", this was left reading the single winner, so a
    /// simulator the app promised to keep could have the runtime underneath it ticked
    /// for `simctl runtime delete`. The result is a simulator that is still installed
    /// and will not boot — not data loss, because Apple will serve the runtime again,
    /// but multi-gigabyte and permanent. `SystemImagesScanner` has the same widening on
    /// the Android side and the comment there names the same failure.
    ///
    /// The kept device is handled first and the rest in sorted order, so two protected
    /// simulators sharing one runtime always produce the same reason — `Set` and
    /// `Dictionary` promise no order, and a reason that changes between scans is a row
    /// whose text moves for no reason the user can see.
    private func resolveRuntimes(
        _ devices: DeviceInventory, keptSimulatorUDID: String?,
        protectedSimulatorUDIDs: Set<String>
    ) -> [String: ProtectionReason] {
        var result: [String: ProtectionReason] = [:]
        // runtimes arrive newest-first from DeviceInventoryLoader
        if let newest = devices.runtimes.first {
            result[newest.identifier] = .newestRuntime
        }

        func protect(_ udid: String, with reason: ProtectionReason) {
            guard let device = devices.simulators.first(where: { $0.udid == udid }) else { return }
            result[device.runtimeIdentifier] = result[device.runtimeIdentifier] ?? reason
        }

        if let keptSimulatorUDID { protect(keptSimulatorUDID, with: .runtimeUsedByKeptDevice) }
        for udid in protectedSimulatorUDIDs.sorted() where udid != keptSimulatorUDID {
            protect(udid, with: .runtimeUsedByProtectedDevice)
        }
        return result
    }

    // MARK: SDK versions

    private func resolveFlutterVersions(_ projects: [DiscoveredProject]) -> [String: ProtectionReason] {
        var result: [String: ProtectionReason] = [:]
        for project in projects {
            guard let version = flutterVersion(in: project.path) else { continue }
            if result[version] == nil {
                result[version] = .sdkInUse(by: project.name)
            }
        }
        return result
    }

    private func flutterVersion(in projectPath: String) -> String? {
        let modern = (projectPath as NSString).appendingPathComponent(".fvmrc")
        if let version = stringValue(forKey: "flutter", inJSONAt: modern) { return version }
        let legacy = (projectPath as NSString).appendingPathComponent(".fvm/fvm_config.json")
        return stringValue(forKey: "flutterSdkVersion", inJSONAt: legacy)
    }

    private func stringValue(forKey key: String, inJSONAt path: String) -> String? {
        guard let data = fileManager.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }

    private func resolveGradleDistributions(
        _ projects: [DiscoveredProject], protected: [String: ProtectionReason]
    ) -> [String: ProtectionReason] {
        var result: [String: ProtectionReason] = [:]
        for project in projects where protected[project.path] != nil {
            for distribution in gradleDistributions(in: project.path) where result[distribution] == nil {
                result[distribution] = .gradleVersionInUse(by: project.name)
            }
        }
        return result
    }

    /// Reads `distributionUrl` from both the plain and the Flutter-nested
    /// wrapper locations, and pulls the distribution name out of
    /// `gradle-8.7-bin.zip`.
    private func gradleDistributions(in projectPath: String) -> [String] {
        let candidates = [
            "gradle/wrapper/gradle-wrapper.properties",
            "android/gradle/wrapper/gradle-wrapper.properties",
        ]
        var distributions: [String] = []
        for relative in candidates {
            let path = (projectPath as NSString).appendingPathComponent(relative)
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                // A commented-out line names a version the project does not use, so
                // protecting it would keep a distribution nothing needs. Trimmed rather
                // than checked in place because the `#` may be indented, and with
                // `.whitespacesAndNewlines` so a CRLF file's trailing `\r` goes too.
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.hasPrefix("#"), trimmed.contains("distributionUrl") else { continue }
                if let distribution = Self.gradleDistribution(fromDistributionURL: trimmed) {
                    distributions.append(distribution)
                }
            }
        }
        return distributions
    }

    /// `…/distributions/gradle-8.7-bin.zip` -> `gradle-8.7-bin`.
    ///
    /// The whole zip name, minus `.zip`, because that is exactly what Gradle names the
    /// folder it unpacks into `~/.gradle/wrapper/dists`. Keeping the name whole is what
    /// lets `GradleScanner` compare directory names directly instead of re-parsing them
    /// with a second copy of this rule.
    ///
    /// Earlier this returned only the version, which merged distributions that are not
    /// the same download: `gradle-9.0-rc-1-bin` with `gradle-9.0-bin`, and `-bin` with
    /// `-all`. A project on one of a merged pair protected the other.
    ///
    /// The character class deliberately excludes `/`, so a match can never run across a
    /// path separator, and requires a digit right after `gradle-` so the `distributions/`
    /// path component cannot start one. `+` is allowed because nightly builds carry a
    /// timestamp such as `gradle-8.9-20240611000000+0000-bin.zip`.
    static func gradleDistribution(fromDistributionURL line: String) -> String? {
        guard let range = line.range(
            of: #"gradle-[0-9][0-9A-Za-z._+-]*\.zip"#, options: .regularExpression)
        else { return nil }
        return String(line[range].dropLast(".zip".count))
    }
}
