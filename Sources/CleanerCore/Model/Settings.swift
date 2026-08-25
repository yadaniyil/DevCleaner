import Foundation

/// The one place a leading `~/` in a stored path becomes a real directory.
///
/// A settings file is hand-editable text and `~/dev` is the form a person writes, but no
/// part of Foundation's file system API expands it: `contentsOfDirectory(atPath:)` and
/// `realpath` both take `~/dev` as the name of a directory called `~` in the working
/// directory, find nothing, and say nothing. So a root written that way used to be
/// accepted, saved, and then silently match nothing for ever — no project discovered, no
/// project protected, and a `PathGuard` entry that could never equal a real path.
///
/// Expanded against a **supplied** home, never `NSHomeDirectory()`. Every home in this
/// package is injected — `SettingsStore`, `CleanerService`, `SettingsModel` all take one —
/// so reading the process's own would make the answer depend on which machine, and which
/// user, happened to run the code.
///
/// Exactly four shapes, and the three that are left alone are left alone on purpose:
///
/// - **`~/…` is expanded.** This is the whole point.
/// - **A bare `~` is not.** It has to be refused as a project root either way, and left as
///   written it fails the "must be absolute" rule that already refuses `.`, `..` and `dev`
///   — one rule instead of two. Leaving it also means `SettingsError.projectRootTooWide`
///   quotes back what the user actually typed rather than a home directory path they never
///   wrote. `~/` **is** expanded, to the home directory itself, and is then refused for
///   being the home directory: it is the `~/…` form with nothing after the slash, and
///   pretending otherwise would need a second rule.
/// - **`~someone/dev` is not.** Resolving another user's home means asking the password
///   database for a real dev machine's accounts, which is exactly the dependency the injected
///   home exists to avoid, and no injected home can answer it. Left alone it is not
///   absolute, so it is refused rather than quietly walked — and a directory belonging to
///   another user is not somewhere this tool should ever delete.
/// - **A `~` anywhere but the start is not.** `/tmp/~foo` and `/Users/x/a~b` are ordinary
///   directory names. Only the first two characters are ever looked at.
public enum TildePath {
    /// `~/work` against a home of `/Users/x` is `/Users/x/work`. Everything else — a bare
    /// `~`, `~someone/dev`, `/tmp/~foo`, `dev`, and any absolute path — comes back
    /// unchanged. See the type's own comment for why each of those is left alone.
    public static func expanded(_ path: String, home: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }
}

public struct Settings: Codable, Sendable, Equatable {
    public var projectRoots: [String]
    public var activeThresholdDays: Int
    /// Devices used within this many days are protected by default, not just the
    /// single most recent one. A simulator or emulator cannot be moved to the
    /// Trash — `simctl delete` and `avdmanager delete` remove it outright — so the
    /// default must not offer a device the user was working with last week.
    public var deviceRecentUseDays: Int
    public var pinnedProjectPaths: [String]
    public var pinnedSimulatorUDID: String?
    public var pinnedAVDName: String?
    public var alwaysSkipScannerIDs: [String]
    public var archiveAgeDays: Int
    public var backgroundScanIntervalHours: Int
    public var launchAtLogin: Bool
    public var menuBarShowsAmount: Bool
    /// Path items go to the Trash instead of being deleted outright. On by
    /// default. Note that trashing does not free disk space until the Trash is
    /// emptied, and that devices ignore this flag — see §7.3 of the spec.
    public var moveToTrash: Bool

    public static func makeDefault(home: String) -> Settings {
        Settings(
            projectRoots: [(home as NSString).appendingPathComponent("dev")],
            activeThresholdDays: 14,
            deviceRecentUseDays: 7,
            pinnedProjectPaths: [],
            pinnedSimulatorUDID: nil,
            pinnedAVDName: nil,
            alwaysSkipScannerIDs: [],
            archiveAgeDays: 30,
            backgroundScanIntervalHours: 6,
            launchAtLogin: false,
            menuBarShowsAmount: true,
            moveToTrash: true
        )
    }

    public func isSkipped(_ scannerID: String) -> Bool {
        alwaysSkipScannerIDs.contains(scannerID)
    }

    /// The same settings with every path-shaped field expanded — see `TildePath`.
    ///
    /// **Two fields are path-shaped, and both are handed to something that cannot expand a
    /// tilde**, so both had the same defect:
    ///
    /// - `projectRoots` reaches `ProjectDiscovery.walk`, which calls
    ///   `contentsOfDirectory(atPath:)`, and `PathGuard.forRun`, which canonicalises with
    ///   `realpath`. A root of `~/dev` discovers nothing and guards nothing.
    /// - `pinnedProjectPaths` is compared against `DiscoveredProject.path`, which is always
    ///   absolute because it is built by walking down from a root. A pin of `~/dev/sample-project`
    ///   therefore matches no project, and "keep this project whatever happens" quietly
    ///   becomes "offer this project's build output". It never reaches the file system
    ///   itself, but a protection that protects nothing is the same failure as a guard that
    ///   guards nothing.
    ///
    /// The rest are not paths and are deliberately untouched: `pinnedSimulatorUDID` is a
    /// UDID, `pinnedAVDName` an AVD name, `alwaysSkipScannerIDs` scanner identifiers, and
    /// the remainder are counts and switches. A `~` in any of them is a literal character
    /// of a name, and expanding it would corrupt the value.
    ///
    /// Internal, not public. `SettingsStore.load` is the one caller and the one boundary; a
    /// second entry point would be a second place for the rule to be applied, forgotten, or
    /// applied twice with a different home.
    func expandingTildePaths(home: String) -> Settings {
        var expanded = self
        expanded.projectRoots = projectRoots.map { TildePath.expanded($0, home: home) }
        expanded.pinnedProjectPaths = pinnedProjectPaths.map { TildePath.expanded($0, home: home) }
        return expanded
    }
}

extension CodingUserInfoKey {
    /// Lets `SettingsStore` hand its home directory to `Settings.init(from:)`, which
    /// needs one to build the default `projectRoots` for a file that predates any key.
    static let settingsHome = CodingUserInfoKey(rawValue: "com.devcleaner.settingsHome")!
}

extension Settings {
    /// Every field is optional on the way in, and a missing one falls back to its
    /// default rather than failing the whole decode.
    ///
    /// Synthesised decoding treats a missing non-optional key as `DecodingError
    /// .keyNotFound`, which `SettingsStore.load()` swallows with `try?` — so one field
    /// added by a new version discards the **entire** file, including
    /// `pinnedSimulatorUDID`. That pin is the only thing standing between a simulator
    /// and a permanent `simctl delete`; there is no Trash to pull it back out of.
    /// Upgrading must never be able to drop it.
    ///
    /// Declared in an extension so the memberwise initialiser survives, and
    /// `encode(to:)` stays synthesised so every field is still written out.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let home = decoder.userInfo[.settingsHome] as? String ?? NSHomeDirectory()
        let fallback = Settings.makeDefault(home: home)

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }

        projectRoots = try value(.projectRoots, fallback.projectRoots)
        activeThresholdDays = try value(.activeThresholdDays, fallback.activeThresholdDays)
        deviceRecentUseDays = try value(.deviceRecentUseDays, fallback.deviceRecentUseDays)
        pinnedProjectPaths = try value(.pinnedProjectPaths, fallback.pinnedProjectPaths)
        // Already optional: absent and `null` both mean "no pin", as before.
        pinnedSimulatorUDID = try container.decodeIfPresent(String.self, forKey: .pinnedSimulatorUDID)
        pinnedAVDName = try container.decodeIfPresent(String.self, forKey: .pinnedAVDName)
        alwaysSkipScannerIDs = try value(.alwaysSkipScannerIDs, fallback.alwaysSkipScannerIDs)
        archiveAgeDays = try value(.archiveAgeDays, fallback.archiveAgeDays)
        backgroundScanIntervalHours = try value(
            .backgroundScanIntervalHours, fallback.backgroundScanIntervalHours)
        launchAtLogin = try value(.launchAtLogin, fallback.launchAtLogin)
        menuBarShowsAmount = try value(.menuBarShowsAmount, fallback.menuBarShowsAmount)
        moveToTrash = try value(.moveToTrash, fallback.moveToTrash)
    }
}

public enum SettingsError: Error, Equatable, CustomStringConvertible {
    /// A project root that names the home directory, `/`, or nothing at all.
    case projectRootTooWide(String)

    public var description: String {
        switch self {
        case .projectRootTooWide(let root):
            return "refused: \(root) is too wide to be a project root. "
                + "Name the folder your code is in, such as ~/dev."
        }
    }
}

public struct SettingsStore: Sendable {
    private let fileURL: URL
    private let home: String

    public init(directory: URL, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.fileURL = directory.appendingPathComponent("settings.json")
        self.home = home
    }

    /// `~/Library/Application Support/DevCleaner`
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DevCleaner", isDirectory: true)
    }

    /// Never throws. A missing or damaged file yields defaults, because a
    /// settings problem must not stop the app from starting.
    ///
    /// A file merely *older* than this build is not damaged: `Settings.init(from:)`
    /// fills in whatever keys it lacks, so the fallback below is reached only by a
    /// file that is absent or unreadable as JSON.
    ///
    /// **This is the one boundary that expands a tilde**, so the CLI, the menu bar app and
    /// a file edited in TextEdit all get the same absolute paths, and `discoverProjects`,
    /// `ProjectDiscovery.walk`, `PickerChoices.projects` and `PathGuard.forRun` never see
    /// anything else. It is here rather than in `Settings.init(from:)` because that
    /// initialiser reads its home out of `decoder.userInfo` and falls back to
    /// `NSHomeDirectory()` when a caller forgets to put one there; expanding on that
    /// fallback would silently resolve against a real dev machine's home. This store always
    /// has an injected one.
    ///
    /// Expanding on the way **in** only. Nothing is written back here: `load()` never
    /// touches the file, so a `~/dev` a user typed into `settings.json` stays as they wrote
    /// it until they save from the settings window, at which point the draft they are
    /// editing — which came from here, already absolute — is written out expanded. That
    /// rewrite is wanted: the file then says exactly which directory the tool will walk and
    /// which one the guard will refuse, with no second interpretation step between the text
    /// and the behaviour.
    public func load() -> Settings {
        let decoder = JSONDecoder()
        decoder.userInfo[.settingsHome] = home
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode(Settings.self, from: data)
        else {
            return .makeDefault(home: home)
        }
        return decoded.expandingTildePaths(home: home)
    }

    /// Throws `SettingsError.projectRootTooWide` rather than storing a project root of
    /// `~` or `/`, and writes nothing at all in that case.
    ///
    /// `PathGuard.forRun` already drops such an entry from the allowed roots while keeping
    /// it forbidden, so no deletion follows from one. What follows instead is a scan:
    /// `ProjectDiscovery` would walk the entire home directory four levels deep, and
    /// `ActivityInspector` would then walk every "project" it found there. The user waits
    /// minutes and gets a list of their Documents folder. This is the first place able to
    /// refuse it; `CleanerService` drops the same values on the way in, because a
    /// hand-edited `settings.json` never passes through here at all.
    public func save(_ settings: Settings) throws {
        for root in settings.projectRoots where Self.isTooWideForAProjectRoot(root, home: home) {
            throw SettingsError.projectRootTooWide(root)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }

    /// True for `/`, for the home directory, for **anything containing** the home
    /// directory, for a relative path, and for a value that names nothing.
    ///
    /// Checked in several passes because a settings file is hand-editable text, not a
    /// resolved path: the tilde is expanded through `TildePath`, which uses the **injected**
    /// home rather than `NSHomeDirectory()`, trailing slashes are dropped, and the result is
    /// compared both as written and as `realpath` resolves it — `/Users/x` and `/private/…`
    /// symlink chains reach the same directory by different strings.
    ///
    /// `TildePath` is the same expansion `SettingsStore.load` and `SettingsModel` use, so
    /// what this refuses and what is actually walked cannot drift apart. It leaves a bare
    /// `~` alone, which still refuses it — as a value that is not absolute, by the guard two
    /// lines below, rather than as the home directory. Both answers are "too wide"; this one
    /// costs no extra rule and lets the refusal quote what the user wrote.
    ///
    /// Two shapes beyond `/` and home itself, each of which reached past the last line of
    /// defence:
    ///
    /// - **An ancestor of home.** `/Users` is home's parent, and it was accepted, so
    ///   `PathGuard.forRun` took it as an allowed root and then permitted `~/Documents`,
    ///   `~/Library/Mail` and `/Users/Shared`. Refusing `/` and home while accepting the
    ///   directory one level above home refuses nothing at all.
    /// - **A relative root.** `.`, `..` and `dev` resolve against the process working
    ///   directory, so what they name depends on where the app was launched from — the
    ///   same reason `PathGuard.validate` refuses a relative path outright. The empty
    ///   string is the degenerate case of this and was already refused.
    ///
    /// No scanner emits a path that would reach any of those places today, so this widens
    /// the guard rather than changing what is deleted. That is the point: the layer exists
    /// for the day a scanner is wrong.
    static func isTooWideForAProjectRoot(_ root: String, home: String) -> Bool {
        var expanded = TildePath.expanded(root, home: home)
        while expanded.count > 1, expanded.hasSuffix("/") { expanded = String(expanded.dropLast()) }

        guard !expanded.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        // After tilde expansion, anything that is not absolute names a different directory
        // depending on where the process is running.
        guard expanded.hasPrefix("/") else { return true }
        if expanded == "/" { return true }

        let homes = Set([home, PathGuard.canonicalise(home) ?? home].map { $0.lowercased() })
        if homes.contains(expanded.lowercased()) { return true }
        if Self.contains(expanded, anyOf: homes) { return true }
        guard let canonical = PathGuard.canonicalise(expanded) else { return false }
        return canonical == "/" || homes.contains(canonical.lowercased())
            || Self.contains(canonical, anyOf: homes)
    }

    /// Whether `path` is a strict ancestor of any of `homes`, which are already lowercased.
    ///
    /// The separator is part of the prefix, per the standing rule: without it `/Users/x`
    /// would count as an ancestor of `/Users/xavier` and a perfectly ordinary home
    /// directory name would refuse its neighbour's roots.
    private static func contains(_ path: String, anyOf homes: Set<String>) -> Bool {
        let prefix = path.lowercased() + (path.hasSuffix("/") ? "" : "/")
        return homes.contains { $0.hasPrefix(prefix) }
    }
}
