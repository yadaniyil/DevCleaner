import Foundation

public enum GroupID: String, Codable, CaseIterable, Sendable {
    case xcodeAndIOS
    case android
    case flutterAndDart
    case projects
    case otherCaches

    public var title: String {
        switch self {
        case .xcodeAndIOS:   return "Xcode & iOS"
        case .android:       return "Android"
        case .flutterAndDart: return "Flutter & Dart"
        case .projects:      return "Projects"
        case .otherCaches:   return "Other caches"
        }
    }
}

public enum RiskLevel: String, Codable, Sendable {
    /// Regenerated automatically by a normal build.
    case safe
    /// Regeneration needs a network fetch that could fail, or the source may be gone.
    case elevated
}

/// `Hashable` so that two rows naming one target can be recognised as one target.
/// `ScanResult` totals de-duplicate on this value before adding anything up; without
/// that, two scanners reporting the same directory would each contribute its full size
/// and the headline would promise space that exists once.
public enum DeletionMethod: Codable, Sendable, Hashable {
    case removePath(String)
    case deleteSimulator(udid: String)
    case deleteSimulatorRuntime(identifier: String)
    case deleteAVD(name: String)

    /// The filesystem path this method touches, when it touches one.
    /// Device deletions go through Apple and Google tooling and have no guarded path.
    public var path: String? {
        if case .removePath(let path) = self { return path }
        return nil
    }
}

public enum ProtectionReason: Codable, Sendable, Equatable, CustomStringConvertible {
    case recentActivity(days: Int)
    case pinnedProject
    case mostRecentlyUsedDevice
    /// Used within `Settings.deviceRecentUseDays`. Deliberately not
    /// `.recentActivity(days:)`, whose text is "changed in the last N days" — a
    /// simulator is booted, not edited, and the user reads these strings.
    case recentlyUsedDevice(days: Int)
    case pinnedDevice
    /// The simulator is **booted right now**, whatever its last-boot time says.
    ///
    /// Highest precedence of every device rule, because it is the only one that cannot
    /// be stale. `lastBootedAt` records when a boot *started*: a simulator booted eight
    /// days ago and still running has a timestamp outside `deviceRecentUseDays`, so
    /// every other rule reads it as untouched for over a week while the user is working
    /// in it. `simctl delete` destroys the device directory — every installed app, its
    /// databases, its user defaults — and there is no Trash and no undo.
    case bootedDevice
    case sdkInUse(by: String)
    case newestRuntime
    case runtimeUsedByKeptDevice
    /// Needed by a simulator that survives a default clean but is not the one labelled
    /// as kept. Deleting it leaves a simulator the app promised to keep, still
    /// installed, that will not boot.
    case runtimeUsedByProtectedDevice
    case gradleVersionInUse(by: String)

    public var description: String {
        switch self {
        case .recentActivity(let days):    return "changed in the last \(days) days"
        case .pinnedProject:               return "pinned"
        case .mostRecentlyUsedDevice:      return "most recently used"
        case .recentlyUsedDevice(let days): return "used in the last \(days) days"
        case .pinnedDevice:                return "pinned"
        case .bootedDevice:                return "running right now"
        case .sdkInUse(let project):       return "used by \(project)"
        case .newestRuntime:               return "newest installed runtime"
        case .runtimeUsedByKeptDevice:     return "used by the simulator you keep"
        case .runtimeUsedByProtectedDevice: return "used by a simulator that is kept"
        case .gradleVersionInUse(let by):  return "used by \(by)"
        }
    }
}

public struct CleanupItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let scannerID: String
    public let group: GroupID
    public let name: String
    public let detail: String?
    public let sizeBytes: Int64
    public let lastUsed: Date?
    public let risk: RiskLevel
    public let protection: ProtectionReason?
    public let method: DeletionMethod
    /// Deletable, shown with its size, and **not ticked when the list first appears**.
    ///
    /// Separate from `protection`, which means "must not be deleted at all". This means
    /// "the user has to ask for it", and it exists for a row that is safe to remove but
    /// expensive to get back — the Android NDK is 5.57 GB that only comes back over the
    /// network, and most projects never build native code, so nothing about it is
    /// obviously worth a several-gigabyte download.
    ///
    /// Defaults to `false` everywhere, so every row that existed before this field keeps
    /// spec §8.3 exactly: deletable means ticked.
    public let startsUnticked: Bool

    /// The measured size may be shared with files that are staying, so removing this row
    /// can free less than `sizeBytes` — sometimes nothing at all.
    ///
    /// True for the pnpm store and the bun cache, 1.83 GB together on a real dev machine. Both
    /// put one copy of a package's files on disk and give every project a second reference
    /// to it, by hard link or by an APFS clone. `du` counts those bytes here and counts
    /// them again inside each project's `node_modules`. Removing the store breaks none of
    /// those projects — the other reference keeps the data alive — but the space does not
    /// come back until the last reference goes.
    ///
    /// Nothing on a real dev machine shares those blocks today: 20,064 pnpm files and 27,401 bun
    /// files all have a link count of 1 and no pnpm virtual store exists. The code cannot
    /// know that, and it changes the first time a project installs from either store, so
    /// the flag is carried rather than the measurement being trusted.
    ///
    /// Defaults to `false`, so every row that existed before this field keeps its old
    /// meaning exactly: `sizeBytes` is the space that comes back.
    public let sizeMayBeShared: Bool

    public init(
        id: String, scannerID: String, group: GroupID, name: String, detail: String?,
        sizeBytes: Int64, lastUsed: Date?, risk: RiskLevel,
        protection: ProtectionReason?, method: DeletionMethod,
        startsUnticked: Bool = false,
        sizeMayBeShared: Bool = false
    ) {
        self.id = id
        self.scannerID = scannerID
        self.group = group
        self.name = name
        self.detail = detail
        self.sizeBytes = sizeBytes
        self.lastUsed = lastUsed
        self.risk = risk
        self.protection = protection
        self.method = method
        self.startsUnticked = startsUnticked
        self.sizeMayBeShared = sizeMayBeShared
    }

    private enum CodingKeys: String, CodingKey {
        case id, scannerID, group, name, detail, sizeBytes, lastUsed, risk, protection
        case method, startsUnticked, sizeMayBeShared
    }

    /// Hand-written for the keys that arrived after this type shipped. A `ScanResult`
    /// encoded before `startsUnticked` or `sizeMayBeShared` existed carries no such key at
    /// all, and a synthesised `decode` would fail the whole document rather than read the
    /// one missing value. `decodeIfPresent` reads each as `false`, which is what every row
    /// written before the field meant.
    ///
    /// **Every field added from here on is read with `decodeIfPresent(...) ?? <default>`.**
    /// `aCleanupItemMissingEverySoftKeyStillDecodes` in `CleanerServiceTests` fails the
    /// moment one is not.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        scannerID = try container.decode(String.self, forKey: .scannerID)
        group = try container.decode(GroupID.self, forKey: .group)
        name = try container.decode(String.self, forKey: .name)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        risk = try container.decode(RiskLevel.self, forKey: .risk)
        protection = try container.decodeIfPresent(ProtectionReason.self, forKey: .protection)
        method = try container.decode(DeletionMethod.self, forKey: .method)
        startsUnticked = try container.decodeIfPresent(Bool.self, forKey: .startsUnticked) ?? false
        sizeMayBeShared =
            try container.decodeIfPresent(Bool.self, forKey: .sizeMayBeShared) ?? false
    }

    public var isDeletable: Bool { protection == nil }

    /// Spec §8.3: everything deletable starts ticked, including elevated risk.
    /// Protected items are shown but never ticked, and so is a row whose scanner asked
    /// to be offered unticked.
    ///
    /// **This, never `isDeletable`, is what an interface ticks.** They were the same value
    /// until `startsUnticked` arrived, and the two Android NDK rows — 5.57 GB — are the
    /// only rows where they differ today. Ticking from `isDeletable` costs a user who
    /// pressed Clean without reading the list a 5.57 GB download they never agreed to.
    /// `ScanResult.defaultSelection` is the list to hand to `CleanerService.clean`.
    public var selectedByDefault: Bool { isDeletable && !startsUnticked }
}
