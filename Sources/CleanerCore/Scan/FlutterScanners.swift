import Foundation

/// `~/.pub-cache`, offered as its two large parts rather than as one row.
///
/// They are separate because they fail differently. `hosted` always comes back from
/// pub.dev on the next `pub get`; `git` packages come from repositories that may have
/// moved, gone private or been deleted, and a lost git package cannot be recovered by
/// rebuilding. Splitting them lets a user who is willing to re-download 7 GB of hosted
/// packages keep the git ones.
public struct PubCacheScanner: CleanupScanner {
    public let id = "flutter.pubCache"
    public let group = GroupID.flutterAndDart
    public let title = "Dart package cache"

    private struct Part {
        let directory: String
        let name: String
        let detail: String
        let risk: RiskLevel
    }

    /// The order the rows appear in, independent of what the directory listing
    /// happens to return.
    private static let parts = [
        Part(directory: "hosted", name: "Hosted packages",
             detail: "re-downloaded from pub.dev on the next build", risk: .elevated),
        Part(directory: "git", name: "Git packages",
             detail: "re-cloned on the next build, but a source repository may no longer exist",
             risk: .elevated),
        Part(directory: "_temp", name: "Temporary downloads",
             detail: "discarded partial downloads; recreated when needed", risk: .safe),
    ]

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let root = context.homePath(".pub-cache")

        // One listing instead of a `fileExists` per part. It settles directory-ness in
        // the same pass, and `~/.pub-cache` really does hold plain files beside its
        // directories — `README.md` is written there by pub itself — which must never
        // be offered as though they were a multi-gigabyte cache.
        let children = ScanHelpers.children(of: root, fileManager: context.fileManager)
            .filter(\.isDirectory)

        // Built by walking `parts`, not the listing, so the rows keep a fixed order.
        // `contentsOfDirectory` promises none, and a list that reshuffles between
        // scans moves the tick boxes under the user's cursor.
        let present = Self.parts.compactMap { part -> (child: ScanHelpers.Child, part: Part)? in
            children.first { $0.name == part.directory }.map { (child: $0, part: part) }
        }

        let sizes = await context.sizeMeasurer.sizes(of: present.map { $0.child.path })

        return present.map { entry in
            let size = ScanHelpers.measured(sizes, entry.child.path)
            return ScanHelpers.item(
                scannerID: id, group: group, path: entry.child.path, name: entry.part.name,
                detail: entry.part.detail,
                sizeBytes: size.bytes,
                lastUsed: entry.child.modified,
                // Both parts come back over the network or not at all, so neither is
                // `.safe` in the sense the model means: a rebuild alone does not
                // restore them.
                risk: entry.part.risk,
                startsUnticked: size.unmeasured)
        }
    }
}

/// Flutter SDKs installed by fvm, one row per installed version, plus fvm's own
/// download cache.
public struct FVMScanner: CleanupScanner {
    public let id = "flutter.fvm"
    public let group = GroupID.flutterAndDart
    public let title = "Flutter SDKs"

    /// fvm has used both locations across its releases, and a machine that has been
    /// through an upgrade can hold SDKs in both. Only `~/fvm/versions` exists on this
    /// machine; the second is checked so an older install is not missed entirely.
    static let relativeRoots = ["fvm/versions", ".fvm/versions"]

    /// Shown as the user of an SDK that `fvm global` points at. Reads as
    /// "used by the fvm global default".
    static let globalDefaultUser = "the fvm global default"

    /// fvm's own download cache: a bare clone of the Flutter repository, kept beside
    /// `versions` so that installing another version is a checkout rather than a full
    /// download. 786.1 MB on a real dev machine, and no scanner claimed it before.
    ///
    /// Offered and ticked like any other cache. It holds no SDK the toolchain is using —
    /// every installed version already sits under `versions` — so nothing breaks when it
    /// goes. The cost lands only on the next `fvm install`, which re-clones roughly the
    /// same 786 MB from GitHub. That network fetch is what `.elevated` means here.
    ///
    /// **`~/fvm/cache.git` is an allowed exact path of `PathGuard.forRun`.** Task 17's
    /// roots stop at `fvm/versions`, deliberately, to keep the `default` symlink out of
    /// reach — so this path is not inside any root and the guard refuses it without that
    /// entry.
    static let mirrorDirectory = "cache.git"
    static let mirrorName = "fvm download cache"
    static let mirrorDetail = "re-cloned from GitHub the next time fvm installs a version"

    private struct Version {
        let name: String
        let path: String
        let modified: Date?
        let isGlobalDefault: Bool
    }

    private struct Mirror {
        let path: String
        let modified: Date?
    }

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let roots = Self.relativeRoots.map(context.homePath)

        // Collected across both roots first, because an SDK in one root can be the
        // global default recorded beside the other.
        let globalDefaults = Set(roots.compactMap {
            Self.globalDefaultTarget(forVersionsRoot: $0, context: context)
        })

        var versions: [Version] = []
        for root in roots {
            for child in ScanHelpers.children(of: root, fileManager: context.fileManager)
                .filter(\.isDirectory)
                .sorted(by: { $0.name < $1.name }) {
                versions.append(Version(
                    name: child.name, path: child.path, modified: child.modified,
                    isGlobalDefault: globalDefaults.contains(Self.standardized(child.path))))
            }
        }

        // The mirror is the sibling of `versions`, one per fvm home, collected in the
        // same pass so it joins the single batched measurement below.
        var mirrors: [Mirror] = []
        for root in roots {
            let fvmHome = (root as NSString).deletingLastPathComponent
            // Directories only, by name. `~/fvm` also holds the `default` symlink and
            // whatever fvm writes beside it, and none of that is this row.
            guard let child = ScanHelpers.children(of: fvmHome, fileManager: context.fileManager)
                .first(where: { $0.name == Self.mirrorDirectory && $0.isDirectory })
            else { continue }
            mirrors.append(Mirror(path: child.path, modified: child.modified))
        }

        // Rule 9: one call with every path this scanner will report on, versions and
        // mirrors together. A second call per kind would defeat the four-`du` cap.
        let sizes = await context.sizeMeasurer.sizes(of: versions.map(\.path) + mirrors.map(\.path))

        let mirrorItems = mirrors.map { mirror in
            let size = ScanHelpers.measured(sizes, mirror.path)
            return ScanHelpers.item(
                scannerID: id, group: group, path: mirror.path, name: Self.mirrorName,
                detail: Self.mirrorDetail,
                sizeBytes: size.bytes,
                lastUsed: mirror.modified,
                // Re-cloned over the network, not rebuilt locally.
                risk: .elevated,
                startsUnticked: size.unmeasured)
        }

        return versions.map { version in
            // A version is kept when **any** discovered project names it, protected or
            // not — deliberately wider than the Gradle rule, which keeps a distribution
            // only for a protected project. A stale project still has to build when the
            // user opens it next month, and re-downloading a Flutter SDK is two
            // gigabytes; a Gradle distribution is a tenth of that.
            let reason = context.protection.flutterVersions[version.name]
                ?? (version.isGlobalDefault ? .sdkInUse(by: Self.globalDefaultUser) : nil)

            // The text is derived from the reason, never from a catch-all sentence. A
            // catch-all has to guess why a version survived, and any single guess is
            // false for some reason that reaches this map.
            let detail: String?
            switch reason {
            case nil:
                detail = "no project asks for this version"
            case .sdkInUse(let user):
                // The only reason the resolver puts in `flutterVersions`, and the only
                // one this scanner adds. Written out so it is visible and pinned.
                detail = "used by \(user)"
            case .some(let other):
                // Nothing else reaches this map today. Should something arrive, the
                // reason's own words are the only text guaranteed not to lie.
                detail = other.description
            }

            let size = ScanHelpers.measured(sizes, version.path)
            return ScanHelpers.item(
                scannerID: id, group: group, path: version.path, name: version.name,
                detail: detail,
                sizeBytes: size.bytes,
                lastUsed: version.modified,
                // Around two gigabytes back over the network, and the toolchain is
                // broken until the download finishes.
                risk: .elevated,
                protection: reason,
                startsUnticked: size.unmeasured)
        } + mirrorItems
    }

    /// The SDK that `fvm global <version>` points at, as an absolute resolved path.
    ///
    /// fvm creates a symlink at `<fvm home>/default` — the sibling of `versions` — and
    /// its own instructions put `<fvm home>/default/bin` on PATH. No project file names
    /// that SDK, so nothing else in a scan protects it, and trashing it leaves the
    /// `flutter` command broken for every project that does not pin a version.
    static func globalDefaultTarget(forVersionsRoot root: String, context: ScanContext) -> String? {
        let fvmHome = (root as NSString).deletingLastPathComponent
        let link = (fvmHome as NSString).appendingPathComponent("default")
        guard let destination = try? context.fileManager.destinationOfSymbolicLink(atPath: link)
        else { return nil }
        // fvm records an absolute target, but a hand-made link may be relative to the
        // directory holding it.
        let absolute = destination.hasPrefix("/")
            ? destination
            : (fvmHome as NSString).appendingPathComponent(destination)
        return standardized(absolute)
    }

    /// Both sides of the comparison go through this, so that two names for one
    /// directory — `/var` against `/private/var`, or a home directory that is itself a
    /// symlink — cannot make the global default look like an SDK nothing uses.
    ///
    /// Equality, not a prefix test: the link names one version directory exactly, and a
    /// prefix would let `3.10.6` be satisfied by `3.10.6-pre`.
    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
