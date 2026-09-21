import Foundation

public enum GroupID: String, Codable, CaseIterable, Sendable {
    case xcodeAndIOS
    case android
    case flutterAndDart
    case projects
    case otherCaches
    /// Large files that are the **user's own** — a 4 GB installer in `~/Downloads`, a
    /// 19 GB folder of language models — rather than anything a tool generated.
    ///
    /// Last in `allCases` on purpose. That order is the order `devcleaner scan` prints its
    /// groups in, and this is the group nothing is ticked in: putting it anywhere but the
    /// end would push the five groups a clean actually acts on further down the list.
    case bigThings

    public var title: String {
        switch self {
        case .xcodeAndIOS:   return "Xcode & iOS"
        case .android:       return "Android"
        case .flutterAndDart: return "Flutter & Dart"
        case .projects:      return "Projects"
        case .otherCaches:   return "Other caches"
        case .bigThings:     return "Big things"
        }
    }
}

public enum RiskLevel: String, Codable, Sendable {
    /// Regenerated automatically by a normal build.
    case safe
    /// Regeneration needs a network fetch that could fail, or the source may be gone.
    case elevated
    /// **It does not come back by itself.** Nothing on this machine and nothing on a
    /// network will re-create it: it is the user's own file.
    ///
    /// Not a third shade of `elevated`. The two above are both promises that the thing
    /// returns, differing only in what that costs; this one withdraws the promise. Two
    /// rules follow from it and both live in code rather than in a sentence: a row like
    /// this is never ticked when a list first appears (`CleanupItem.startsUnticked`), and
    /// the executor **always** puts it in the Trash whatever `Settings.moveToTrash` says
    /// — see `CleanupItem.goesToTheTrash(moveToTrash:)`.
    case irreplaceable
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
    /// The newest device support folder for one device model, which is the one Xcode uses
    /// **now**.
    ///
    /// `~/Library/Developer/Xcode/iOS DeviceSupport` holds one folder per OS build a
    /// device was ever connected on: four of them on a real dev machine, 27 GB, of which
    /// three are old betas and one is the release the phone is running today. Offering all
    /// four costs the user about 7 GB of symbols copied off the phone again — several
    /// minutes of "Preparing device for development" before their next build — for a
    /// folder that was never dead weight. The older builds are; this reason is what keeps
    /// the live one.
    case newestDeviceSupport

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
        // Singular and possessive-free, because it is printed both on its own row and
        // after a count — "2 kept · newest for this device · 13.0 GB".
        case .newestDeviceSupport:         return "newest for this device"
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

    /// Why this row starts unticked, when the reason is one the user should read before
    /// they tick it.
    ///
    /// `startsUnticked` on its own says "the user has to ask for it" and says nothing about
    /// why. That was enough while the only such row was the Android NDK, where the size and
    /// the `risk` told the whole story. It is not enough for the row this field was added
    /// for: the build folders of a project the user has been working in this fortnight.
    /// Those are offered — the deck asks about one project at a time and the user answers
    /// for that project — and what makes the offer honest is the sentence that comes with
    /// it, "you changed this in the last 14 days, so its next build starts from scratch".
    ///
    /// **Not `protection`.** Protection means *must not be deleted at all*: the executor
    /// refuses such a row, `PathGuard` refuses its path, and no interface may tick it. This
    /// means *ask first*, which is a weaker and different thing — and the two must not be
    /// confused, because a pin is still a hard no and reaches the user as `protection`.
    ///
    /// **`nil` for an unmeasured row.** Every scanner routes a folder `du` could not size
    /// through `startsUnticked` as well, and that is not a reason worth printing: it is not
    /// about the project, there is nothing for the user to weigh, and the row's size is 0.
    /// Among the rows of `projects.buildOutput`, therefore, `startsUnticked &&
    /// untickedReason == nil` is exactly "unmeasured" — and `ProjectDeck` leaves those out
    /// by asking for a size above zero.
    ///
    /// **It is not that for every scanner**, and two of them say so deliberately. The rows
    /// of `GroupID.bigThings` and of the two `DeckDealing.mentionOnly` scanners are never
    /// ticked at all, and a folder in `~/.cache` whose tool `XDGCacheScanner` cannot name is
    /// offered unticked as well — none of them with a reason here, because in each case the
    /// reason is a decision about the app rather than a `ProtectionReason` about the row.
    /// A reader wanting "unmeasured" for one of those has `sizeBytes == 0`.
    ///
    /// Set only alongside `startsUnticked`; `anUntickedReasonAlwaysComesWithAnUntickedRow`
    /// pins that for every row every committed scanner produces.
    ///
    /// Defaults to `nil` and decodes with `decodeIfPresent`, so a cached scan written
    /// before it existed still loads and means what it meant.
    public let untickedReason: ProtectionReason?

    public init(
        id: String, scannerID: String, group: GroupID, name: String, detail: String?,
        sizeBytes: Int64, lastUsed: Date?, risk: RiskLevel,
        protection: ProtectionReason?, method: DeletionMethod,
        startsUnticked: Bool = false,
        sizeMayBeShared: Bool = false,
        untickedReason: ProtectionReason? = nil
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
        self.untickedReason = untickedReason
    }

    private enum CodingKeys: String, CodingKey {
        case id, scannerID, group, name, detail, sizeBytes, lastUsed, risk, protection
        case method, startsUnticked, sizeMayBeShared, untickedReason
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
        untickedReason =
            try container.decodeIfPresent(ProtectionReason.self, forKey: .untickedReason)
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

    /// Whether removing this row puts it in the Trash, where it can still be got back.
    ///
    /// **One function rather than the test written out at each of the three places that ask
    /// it.** The executor branches on it to choose between `trash` and `remove`; the CLI's
    /// plan splits a selection on it to say how much is
    /// recoverable; and `CleanerService.warnings` raises the Trash sentence from it. Those
    /// three spelled `moveToTrash` on its own until `.irreplaceable` arrived, and the first
    /// one to be updated in isolation would have been a screen promising a user's 4 GB
    /// download was deleted outright while it sat in their Trash — or the reverse, which is
    /// worse.
    ///
    /// Two things make it false, and they are not the same thing:
    ///
    /// 1. **No path.** That is exactly the three device cases — `simctl delete`,
    ///    `simctl runtime delete` and `avdmanager delete avd` have no Trash equivalent, so
    ///    the setting cannot apply to them however it is set. (The one path that really
    ///    does trash a device is the fallback used when the Android command line tools are
    ///    missing, which is why `Warning.devicesAreRemovedPermanently` says "normally";
    ///    this answers for the deletion the row asks for, and the executor's own record is
    ///    what says afterwards where each row really went.)
    /// 2. **Permanent mode, for anything that comes back.** That is the setting doing its
    ///    job.
    ///
    /// What the setting may **not** reach is `.irreplaceable`: a file of the user's own is
    /// never removed outright, because there would be nothing anywhere to get it back from.
    public func goesToTheTrash(moveToTrash: Bool) -> Bool {
        guard method.path != nil else { return false }
        return moveToTrash || risk == .irreplaceable
    }
}
