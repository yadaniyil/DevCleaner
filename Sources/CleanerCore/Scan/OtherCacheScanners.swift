import Foundation

/// Shared shape for scanners that offer a fixed set of known locations.
///
/// Every location is named in code. None of these scanners walks a directory asking
/// what looks big — the whole point of the group is that adding a location is a
/// deliberate change someone has to review.
struct FixedLocationScan {
    let relativePath: String
    let name: String
    let detail: String?
    /// Overrides the scanner-wide risk when one location has a different recovery cost.
    let risk: RiskLevel?
    /// See `CleanupItem.sizeMayBeShared`. Only the pnpm store and the bun cache set it,
    /// and only they should: it says the measured bytes may be shared with files that are
    /// staying, so the row cannot promise to free its own size.
    let sizeMayBeShared: Bool

    init(relativePath: String, name: String, detail: String?,
         risk: RiskLevel? = nil, sizeMayBeShared: Bool = false) {
        self.relativePath = relativePath
        self.name = name
        self.detail = detail
        self.risk = risk
        self.sizeMayBeShared = sizeMayBeShared
    }
}

extension FixedLocationScan {
    /// A location that is present, paired with the absolute path it was found at.
    ///
    /// A named type rather than a tuple, matching `GradleScanner.Candidate`.
    private struct Found {
        let path: String
        let location: FixedLocationScan
    }

    static func items(
        _ locations: [FixedLocationScan], scannerID: String, group: GroupID,
        context: ScanContext, risk: RiskLevel = .safe
    ) async -> [CleanupItem] {
        let present = locations.compactMap { location -> Found? in
            let path = context.homePath(location.relativePath)
            // Directory-ness is checked, not just existence. A plain file left at one of
            // these paths — a leftover from a half-restored backup, or a lock file a tool
            // wrote where its cache used to be — would otherwise be offered under the
            // name of a multi-gigabyte cache and measured as zero.
            var isDirectory: ObjCBool = false
            guard context.fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return nil }
            return Found(path: path, location: location)
        }

        // One call with every path. `sizes(of:)` holds four `du` processes open at most,
        // and a call per location defeats that cap.
        let sizes = await context.sizeMeasurer.sizes(of: present.map(\.path))

        return present.map { found in
            let size = ScanHelpers.measured(sizes, found.path)
            return ScanHelpers.item(
                scannerID: scannerID, group: group, path: found.path,
                name: found.location.name, detail: found.location.detail,
                sizeBytes: size.bytes, risk: found.location.risk ?? risk,
                startsUnticked: size.unmeasured,
                sizeMayBeShared: found.location.sizeMayBeShared)
        }
    }
}

/// The two places CocoaPods keeps downloaded state, offered as separate rows.
///
/// Both are `.elevated`. Neither is rebuilt by a build: the cache comes back from the
/// CDN and the spec repos come back from GitHub, so a clean on a bad connection costs
/// the user a `pod install` they cannot run.
public struct CocoaPodsScanner: CleanupScanner {
    public let id = "other.cocoapods"
    public let group = GroupID.otherCaches
    public let title = "CocoaPods"

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        await FixedLocationScan.items([
            FixedLocationScan(relativePath: "Library/Caches/CocoaPods",
                              name: "CocoaPods cache",
                              detail: "re-downloaded on the next pod install"),
            // "re-fetched", not "re-cloned": since CocoaPods 1.8 the standard `trunk`
            // repository has been a CDN mirror rather than a git clone. The wording also
            // remains accurate for any additional spec repositories a user configures.
            FixedLocationScan(relativePath: ".cocoapods/repos",
                              name: "CocoaPods spec repos",
                              detail: "re-fetched on the next pod install"),
        ], scannerID: id, group: group, context: context, risk: .elevated)
    }
}

/// The global download caches of the JavaScript package managers.
///
/// All `.elevated` for the same reason as the Dart pub cache: every one of them comes
/// back over the network or not at all, and a build cannot run until it does.
///
/// pnpm and bun put one copy of a package's files on disk and give every project a second
/// reference to it, by hard link or by an APFS clone. The bytes `du` reports for those two
/// rows are therefore counted again inside each project that installed from them. Removing
/// the store does not break those projects — the other reference keeps the data alive —
/// but it also does not free that share of the space until those projects go too.
///
/// Those two rows carry `CleanupItem.sizeMayBeShared`, and `ScanResult.possiblySharedBytes`
/// adds them up, so the interface can say what part of its headline is not promised. The
/// other two rows do not: npm's `_cacache` and Yarn's cache are content-addressed stores
/// that are **copied** into `node_modules`, so their bytes really do come back.
public struct JSPackageCacheScanner: CleanupScanner {
    public let id = "other.jsPackages"
    public let group = GroupID.otherCaches
    public let title = "JavaScript package caches"

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        await FixedLocationScan.items([
            FixedLocationScan(relativePath: ".npm/_cacache", name: "npm cache",
                              detail: "re-downloaded on the next npm install"),
            FixedLocationScan(relativePath: "Library/pnpm/store", name: "pnpm store",
                              detail: "re-downloaded on the next pnpm install",
                              sizeMayBeShared: true),
            FixedLocationScan(relativePath: "Library/Caches/Yarn", name: "Yarn cache",
                              detail: "re-downloaded on the next yarn install"),
            // `~/.bun/install/cache`, never `~/.bun`: that directory also holds `bin`,
            // the globally installed executables, which no install brings back.
            FixedLocationScan(relativePath: ".bun/install/cache", name: "bun cache",
                              detail: "re-downloaded on the next bun install",
                              sizeMayBeShared: true),
        ], scannerID: id, group: group, context: context, risk: .elevated)
    }
}

/// Small, fully regenerable tool caches that live directly under the home directory.
///
/// These paths are intentionally exact. In particular, the scanner never offers
/// `~/.android`, whose siblings include `adbkey` and `debug.keystore`.
public struct LocalToolCacheScanner: CleanupScanner {
    public let id = "other.localToolCaches"
    public let group = GroupID.otherCaches
    public let title = "Local tool caches"

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        await FixedLocationScan.items([
            FixedLocationScan(relativePath: ".android/cache", name: "Android download cache",
                              detail: "re-downloaded by Android tools when needed",
                              risk: .elevated),
            FixedLocationScan(relativePath: ".android/build-cache", name: "Android build cache",
                              detail: "rebuilt on the next Android build"),
            FixedLocationScan(relativePath: ".dartServer", name: "Dart analyzer cache",
                              detail: "rebuilt when the analyzer next runs"),
        ], scannerID: id, group: group, context: context)
    }
}

/// Developer tool caches under `~/Library/Caches`, from a fixed allowlist.
///
/// `~/Library/Caches` holds caches for every app on the machine — 158 folders on the
/// machine this was written against, most of them Apple daemons, browsers and mail.
/// This scanner therefore never enumerates that directory looking for things to
/// delete. It looks for names it already knows, and adding a name is a deliberate
/// code change, which is the point.
public struct LibraryCachesScanner: CleanupScanner {
    public let id = "other.libraryCaches"
    public let group = GroupID.otherCaches
    public let title = "Developer tool caches"

    public init() {}

    private struct Allowed {
        /// Relative to `~/Library/Caches`. May name a subfolder.
        let folder: String
        let name: String
        let detail: String
        let risk: RiskLevel
        /// The tool appends a version to the folder name, so the exact name never
        /// finds it and its parent has to be listed instead.
        ///
        /// Off for everything else on purpose. A blanket prefix fallback offers
        /// whatever happens to start with an allowlisted name: with no
        /// `~/Library/Caches/com.apple.dt.Xcode` present it would offer
        /// `com.apple.dt.Xcode.ITunesSoftwareService` — a different cache, under the
        /// name "Xcode" — and that is exactly the guess the allowlist exists to stop.
        let versioned: Bool
    }

    private static let allowed: [Allowed] = [
        Allowed(folder: "com.apple.dt.Xcode", name: "Xcode",
                detail: "rebuilt the next time Xcode runs", risk: .safe, versioned: false),
        Allowed(folder: "org.swift.swiftpm", name: "Swift Package Manager",
                detail: "re-downloaded on the next package resolve",
                risk: .elevated, versioned: false),
        Allowed(folder: "Homebrew", name: "Homebrew downloads",
                detail: "re-downloaded on the next brew install",
                risk: .elevated, versioned: false),
        Allowed(folder: "JetBrains", name: "JetBrains IDEs",
                detail: "rebuilt the next time the IDE opens a project",
                risk: .safe, versioned: false),
        Allowed(folder: "Google/AndroidStudio", name: "Android Studio",
                detail: "rebuilt the next time the IDE opens a project",
                risk: .safe, versioned: true),
    ]

    private struct Found {
        let path: String
        let entry: Allowed
        let detail: String
    }

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let root = context.homePath("Library/Caches")

        var found: [Found] = []
        for entry in Self.allowed {
            let path = (root as NSString).appendingPathComponent(entry.folder)
            if isDirectory(path, context) {
                found.append(Found(path: path, entry: entry, detail: entry.detail))
                continue
            }
            guard entry.versioned else { continue }

            // Only the named parent is listed — `~/Library/Caches/Google`, never
            // `~/Library/Caches` itself — and only children whose name starts with the
            // allowlisted one are taken. On a real dev machine that parent also holds
            // `Chrome` and `Chrome-headless`, which must never be offered.
            let parent = (path as NSString).deletingLastPathComponent
            let prefix = (path as NSString).lastPathComponent
            let matches = ScanHelpers.children(of: parent, fileManager: context.fileManager)
                .filter { $0.isDirectory && $0.name.hasPrefix(prefix) }
                // `contentsOfDirectory` promises no order, and a list that reshuffles
                // between scans moves the tick boxes under the user's cursor.
                .sorted { $0.name < $1.name }
            found.append(contentsOf: matches.map {
                // Two versions of one IDE produce two rows with the same name, so the
                // folder name goes in the detail. Without it the user is asked to pick
                // between two rows they cannot tell apart.
                Found(path: $0.path, entry: entry, detail: "\($0.name), \(entry.detail)")
            })
        }

        let sizes = await context.sizeMeasurer.sizes(of: found.map(\.path))

        return found.map { entry in
            let size = ScanHelpers.measured(sizes, entry.path)
            return ScanHelpers.item(
                scannerID: id, group: group, path: entry.path, name: entry.entry.name,
                detail: entry.detail, sizeBytes: size.bytes, risk: entry.entry.risk,
                startsUnticked: size.unmeasured)
        }
    }

    private func isDirectory(_ path: String, _ context: ScanContext) -> Bool {
        var isDirectory: ObjCBool = false
        guard context.fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        else { return false }
        return isDirectory.boolValue
    }
}
