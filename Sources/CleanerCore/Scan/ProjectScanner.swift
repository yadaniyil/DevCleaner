import Foundation

/// Build and dependency folders inside the user's own project directories.
///
/// Every other scanner in this package works on a shared cache that belongs to a tool.
/// This one reaches inside the directories the user writes code in, so it is the only
/// one that can break the rule the whole app is built around: **never touch the build
/// folders of a project the user is working on right now.**
///
/// It does not decide what "working on" means. `ProtectionResolver` (Task 8) already
/// did, from the user's pins and from file activity, and this scanner only reads
/// `ProtectionSet.projects`. Re-deriving any part of that here would give the app two
/// answers to the same question, and the one the user sees in the settings window would
/// not be the one that decides what gets trashed.
///
/// A protected project still gets one row, marked protected, carrying the total of
/// everything it is holding. Dropping it from the list would answer "where did my 40 GB
/// go?" with silence.
public struct ProjectBuildOutputScanner: CleanupScanner {
    public let id = "projects.buildOutput"
    public let group = GroupID.projects
    public let title = "Project build folders"

    public init() {}

    /// Relative paths inside a project that a build regenerates. Each is a separate row,
    /// so one project can be partly cleaned — a user who wants the 4 GB back from
    /// `build` but is about to fly with no network can leave `ios/Pods` alone.
    ///
    /// Fixed list, never a walk of the project looking for what seems big: `lib`, `test`
    /// and `assets` are all large in a real Flutter project and all of them are the
    /// user's own work.
    static let buildFolders = [
        "build", ".dart_tool", ".symlinks",
        "ios/Pods", "macos/Pods",
        "android/.gradle", "android/build",
        "node_modules",
    ]

    /// The folders a build alone does not bring back. `pod install` and `npm install`
    /// both go to the network, and a lockfile can name a version that has since been
    /// unpublished — which is exactly what `.elevated` means in this model. The rest are
    /// rebuilt locally from the project and the package caches, so they are `.safe`.
    static let networkRestored: Set<String> = ["ios/Pods", "macos/Pods", "node_modules"]

    /// Where a git worktree made for an agent session lives, relative to the project.
    ///
    /// `buildFolders` above is a fixed list of paths, and a worktree's build output is
    /// not at a fixed path: the folder in the middle is the worktree's name. Without this
    /// the biggest single folder on a real dev machine is invisible —
    /// `Sample iOS App/.claude/worktrees/feature-sync/build` is **5.99 GB**,
    /// while the project's own rows add up to 2.68 GB.
    ///
    /// One row per worktree, never one row for `worktrees`, so a user can hand back the
    /// build output of a worktree they have finished with and keep the one they are
    /// working in.
    ///
    /// Nothing else in the app reaches these folders. `ProjectDiscovery` returns at the
    /// first project marker it meets and never descends further, so a worktree is not a
    /// project of its own — and relaxing its dot-directory skip recovers nothing, because
    /// the skip is never reached.
    static let worktreeContainer = ".claude/worktrees"

    private struct Candidate {
        let project: DiscoveredProject
        /// The path relative to the project, which is also the row's name.
        let relative: String
        let path: String
    }

    private struct ProtectedRoot {
        let path: String
        let reason: ProtectionReason
    }

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        // Longest path first, so a project nested inside another protected project is
        // attributed to the nearest one that covers it. Ties broken by path so the
        // order never depends on how the dictionary happened to hash.
        let roots: [ProtectedRoot] = context.protection.projects.map {
            ProtectedRoot(path: $0.key, reason: $0.value)
        }
        let protectedRoots = roots.sorted { left, right in
            if left.path.count != right.path.count { return left.path.count > right.path.count }
            return left.path < right.path
        }

        var candidates: [Candidate] = []
        // `ProjectDiscovery.discover(roots:)` appends per root and never de-duplicates,
        // so a user whose `projectRoots` hold both `~/dev` and `~/dev/app` gets that
        // project twice. Two rows sharing one `CleanupItem.id` would double the
        // reclaimable total and give the UI two rows it cannot tell apart.
        var seen: Set<String> = []
        for project in context.projects {
            // The worktree folders join the fixed list here rather than being handled
            // apart, so every one of them goes through the same real-directory check, the
            // same de-duplication, the same protection rule and the same single
            // measurement batch as `build` itself.
            let relatives = Self.buildFolders + Self.worktreeBuildFolders(
                in: project.path, fileManager: context.fileManager)
            for relative in relatives {
                let path = (project.path as NSString).appendingPathComponent(relative)
                guard Self.isRealDirectory(path, fileManager: context.fileManager),
                      seen.insert(path).inserted
                else { continue }
                candidates.append(Candidate(project: project, relative: relative, path: path))
            }
        }

        // One call with every path, protected ones included. `sizes(of:)` holds four
        // `du` processes open at most, and a call per folder defeats that cap — with 257
        // projects on a real dev machine that is the difference between four processes and
        // several hundred.
        let sizes = await context.sizeMeasurer.sizes(of: candidates.map(\.path))

        var items: [CleanupItem] = []
        var protectedOrder: [String] = []
        var protectedTotals: [String: Int64] = [:]

        for candidate in candidates {
            let measurement = ScanHelpers.measured(sizes, candidate.path)
            let size = measurement.bytes

            // Containment, not a lookup of the candidate's own project. A project can
            // sit inside another one when `Settings.projectRoots` names both — a melos
            // workspace member, or the `example` app of a Flutter plugin — and a folder
            // inside a protected project is inside it whatever row it would be labelled
            // with. The user's rule is about the directory, not the label.
            guard let owner = protectedRoots.first(where: {
                Self.path(candidate.path, isInsideOrEqualTo: $0.path)
            }) else {
                items.append(ScanHelpers.item(
                    scannerID: id, group: group, path: candidate.path,
                    name: candidate.relative, detail: candidate.project.name,
                    sizeBytes: size,
                    risk: Self.networkRestored.contains(candidate.relative) ? .elevated : .safe,
                    startsUnticked: measurement.unmeasured))
                continue
            }

            if protectedTotals[owner.path] == nil { protectedOrder.append(owner.path) }
            protectedTotals[owner.path, default: 0] += size
        }

        // Emitted in the order the folders were met, never by walking the dictionary —
        // `Dictionary` promises no order, and a list that reshuffles between scans moves
        // the tick boxes under the user's cursor.
        for rootPath in protectedOrder {
            guard let root = protectedRoots.first(where: { $0.path == rootPath }) else { continue }
            let name = context.projects.first { $0.path == rootPath }?.name
                ?? (rootPath as NSString).lastPathComponent

            items.append(CleanupItem(
                id: "\(id)|\(rootPath)",
                scannerID: id, group: group,
                name: name,
                detail: Self.detail(for: root.reason),
                sizeBytes: protectedTotals[rootPath] ?? 0,
                lastUsed: nil,
                risk: .safe,
                protection: root.reason,
                // The project's own directory, so the row names what it is reporting on
                // and keeps a stable identity across scans. It is the one path in this
                // app that is a directory of the user's source code, and three
                // independent things keep it harmless rather than one: `protection` is
                // non-nil so `isDeletable` is false and the UI never ticks it, the
                // executor acts only on selected rows, and `PathGuard.forRun` registers
                // every discovered project directory as a forbidden target.
                //
                // The third of those belongs to Task 17 and is pinned there, by
                // `everyDiscoveredProjectDirectoryIsAForbiddenTargetOfTheRunGuard` in
                // `ExecutorTests`: it builds the real run guard, hands the executor a
                // summary row with its protection stripped off, and asserts the project
                // directory survives. Nothing in this package's tests can pin it from
                // here — `theProtectedSummaryRowNamesTheProjectAndIsRefusedByPathGuard`
                // below constructs its own `PathGuard(forbiddenTargets: [project.path])`
                // and asserts the guard honours it, which restates `PathGuard`'s own
                // contract and says nothing about what the executor registers. What that
                // test does pin is this line: the row's target is the project directory.
                method: .removePath(rootPath)))
        }

        return items
    }

    /// The `build` folder of every worktree under `.claude/worktrees`, as paths relative
    /// to the project — the same shape as `buildFolders`, so the caller treats them
    /// identically and the row is named `.claude/worktrees/<name>/build`.
    ///
    /// Only the worktree directories are listed here; whether each `build` is a real
    /// directory is settled by the shared check in `scan`, so a worktree with no build
    /// output and a plain file named `build` are both dropped there.
    ///
    /// Sorted by worktree name: `contentsOfDirectory` promises no order, and a list that
    /// reshuffles between scans moves the tick boxes under the user's cursor.
    static func worktreeBuildFolders(in projectPath: String, fileManager: FileManager) -> [String] {
        let container = (projectPath as NSString).appendingPathComponent(worktreeContainer)
        return ScanHelpers.children(of: container, fileManager: fileManager)
            .filter(\.isDirectory)
            .sorted { $0.name < $1.name }
            .map { "\(worktreeContainer)/\($0.name)/build" }
    }

    /// True when `path` is `root` itself or lies inside it.
    ///
    /// The separator is the whole point. `hasPrefix(root)` on its own reports that
    /// `sample-flutterflow` is inside `sample-flutter`, and the fixture has
    /// `sample-flutter`, `sample-flutter-002`, `sample-flutter-inplace` and
    /// `sample-flutterflow` sitting side by side under `~/dev`, plus `demo-repo`
    /// beside `demo-repo copy`. Without the separator, protecting one of those silently
    /// withdraws the other three from the clean and reports their space under a name
    /// that is not theirs.
    static func path(_ path: String, isInsideOrEqualTo root: String) -> Bool {
        path.hasPrefix(root + "/") || path == root
    }

    /// A candidate has to be a real directory.
    ///
    /// `fileExists(atPath:)` alone is true for a plain file, and a lock file or a stray
    /// script named `build` would be offered under the name of a multi-gigabyte folder
    /// and measured as zero. `attributesOfItem` does not follow symbolic links, which
    /// rules out the other case: a `build` pointing at another disk measures as nothing,
    /// because `du` does not follow a link given as its argument, so the row would claim
    /// zero bytes while trashing the link frees nothing and costs the user their link.
    static func isRealDirectory(_ path: String, fileManager: FileManager) -> Bool {
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        return attributes?[.type] as? FileAttributeType == .typeDirectory
    }

    /// The text under a protected project's row, derived from the reason itself.
    ///
    /// Never one sentence for everything protected. A catch-all has to guess why the
    /// project survived, and any single guess is false for the other reason: "you
    /// changed it recently" is wrong for a project the user pinned a year ago, and
    /// "you pinned it" is wrong for every project that is merely active.
    ///
    /// Exhaustive with no `default`, so a new `ProtectionReason` case cannot slip
    /// through with a sentence that was written for something else — it stops the build
    /// here instead.
    static func detail(for reason: ProtectionReason) -> String {
        switch reason {
        case .recentActivity(let days):
            return "changed in the last \(days) days"
        case .pinnedProject:
            return "pinned in settings"
        case .mostRecentlyUsedDevice, .recentlyUsedDevice, .pinnedDevice, .bootedDevice,
             .sdkInUse, .newestRuntime, .runtimeUsedByKeptDevice,
             .runtimeUsedByProtectedDevice, .gradleVersionInUse:
            // None of these reach `ProtectionSet.projects` today — they belong to
            // devices, SDKs and runtimes. Should one arrive, the reason's own words are
            // the only text guaranteed not to lie about it.
            return reason.description
        }
    }
}
