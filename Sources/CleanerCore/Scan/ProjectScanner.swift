import Foundation

/// Build and dependency folders inside the user's own project directories.
///
/// Every other scanner in this package works on a shared cache that belongs to a tool.
/// This one reaches inside the directories the user writes code in, so it is the only
/// one that can break the rule the whole app is built around: **nothing ever ticks the
/// build folders of a project the user is working on right now.**
///
/// It does not decide what "working on" means. `ProtectionResolver` (Task 8) already
/// did, from the user's pins and from file activity, and this scanner only reads
/// `ProtectionSet.projects`. Re-deriving any part of that here would give the app two
/// answers to the same question, and the one the user sees in the settings window would
/// not be the one that decides what gets trashed.
///
/// **The two reasons a project is protected now part company here**, and the difference is
/// between *never* and *not without being asked*:
///
/// - A **pin** is the user's own hard no. Nothing of that project is offered. It gets one
///   row, marked `protection`, carrying the total of everything it is holding — dropping it
///   would answer "where did my 40 GB go?" with silence.
/// - **Recent activity** is something to tell the user, not a reason to hide the folder.
///   Its folders get ordinary per-folder rows with real sizes, `startsUnticked` and an
///   `untickedReason` saying why. No interface ticks them, `ScanResult.defaultSelection`
///   leaves them out, and so `cleanDefault` — the blind one-click clean this rule was
///   written for — cannot touch them.
///
/// The second half used to be the first. A read-only scan of a real dev machine is what
/// changed it: **every** project holding build output came back "kept: changed in the last
/// 14 days" — Sample Game 3.3 GB, Photo Tool 2.8 GB, this repository 588 MB — so a
/// window whose whole job is to show one project at a time and ask about it had nothing to
/// show. Withholding is right when the user cannot see what goes; when they are looking at
/// the folder and pressing a button under it, it is the tool refusing to answer.
public struct ProjectBuildOutputScanner: CleanupScanner {
    /// The identifier, as a static so the three places that have to recognise one of these
    /// rows can read it rather than spell it.
    ///
    /// `Executor` renames a row of this scanner before trashing it and no other scanner's,
    /// and `ProjectDeck` builds its cards from these rows and no others; both used to carry
    /// the string as a literal. It is also persisted in `Settings.alwaysSkipScannerIDs`, so
    /// the value cannot change — `theRegistryHoldsExactlyTheseSeventeenIdentifiers` is what
    /// holds it still.
    public static let scannerID = "projects.buildOutput"

    public let id = Self.scannerID
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
    ///
    /// `.build` was missing until the deck was built, and it was the most expensive
    /// omission on this machine: `~/dev/workspace-one/sample-game/.build` alone is 946 MB, and
    /// nothing in the app could see it. `DerivedData` joins it because Xcode can be told
    /// to keep derived data beside the project rather than under `~/Library`, in which
    /// case `DerivedDataScanner` never meets it.
    static let buildFolders = [
        // Flutter and Dart, plus the per-platform folders a cross-platform project
        // builds into.
        "build", ".dart_tool", ".symlinks",
        "ios/build", "android/build", "app/build",
        // SwiftPM and Xcode, when their output lands inside the project.
        ".build", "DerivedData",
        // CocoaPods: at the root of a plain iOS project, and under each platform folder
        // of a Flutter one.
        "Pods", "ios/Pods", "macos/Pods",
        // Gradle's per-project caches.
        ".gradle", "android/.gradle",
        // JavaScript, and the framework caches that sit beside `node_modules`.
        "node_modules",
        ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".expo",
    ]

    /// The folders a build alone does not bring back. `pod install` and `npm install`
    /// both go to the network, and a lockfile can name a version that has since been
    /// unpublished — which is exactly what `.elevated` means in this model. The rest are
    /// rebuilt locally from the project and the package caches, so they are `.safe`.
    ///
    /// All three spellings of `Pods`, because the consequence is the same wherever it
    /// sits. Leaving the root-level one off would mark a plain iOS project's 400 MB of
    /// pods as safe while the identical folder under `ios/` is elevated.
    static let networkRestored: Set<String> = [
        "Pods", "ios/Pods", "macos/Pods", "node_modules",
    ]

    /// Cargo's output directory, which is the one entry that cannot be on the fixed list.
    ///
    /// `target` is an ordinary directory name. A Flutter project has one, a
    /// Makefile-driven C project has one, and in both it is the user's own work.
    /// `Cargo.toml` at the root is the one thing that says this `target` is Cargo's, so
    /// the manifest is the condition rather than the name.
    static func cargoTargetFolder(in projectPath: String, fileManager: FileManager) -> [String] {
        let manifest = (projectPath as NSString).appendingPathComponent("Cargo.toml")
        return fileManager.fileExists(atPath: manifest) ? ["target"] : []
    }

    /// The prefix of a build-variant folder — `.build-rel`, `.build-cows`, `.build-pond`.
    static let buildVariantPrefix = ".build-"

    /// What a `.build-…` directory has to hold before it is offered.
    ///
    /// `~/dev/workspace-one/sample-game` holds ten of these beside its `.build`, ≈3.2 GB
    /// together, each with an Xcode derived-data tree inside it. The suffix is invented on
    /// the spot by whoever ran the build, so no fixed list can name them and this is the
    /// one place the scanner looks at what a folder *contains*.
    ///
    /// The prefix alone is deliberately not enough. `.build-notes`, `.build-scripts` and
    /// `.build-config` are all equally plausible names for something the user wrote by
    /// hand, and this is the scanner that reaches inside the directories they write code
    /// in — so a candidate has to carry something only a build writes. The first four
    /// names are what Xcode's derived data holds at its top level; the last two are
    /// SwiftPM's build directory.
    ///
    /// **Every name here has to be one a person would not choose.** `debug` and `release`
    /// were on this list and were taken off it, because they are ordinary English words: a
    /// hand-written `.build-scripts/` holding a `release` script, or a `.build-config/`
    /// with a `release/` directory of plists in it, matched — and then *two* rules turned
    /// against the user at once. The folder was offered for deletion, and
    /// `ActivityInspector.isIgnored` asks this same question, so editing it stopped counting
    /// as working on the project. Nothing is lost by dropping them: SwiftPM's build
    /// directory always carries `checkouts` and `workspace-state.json` beside its `debug`,
    /// and Xcode's derived data carries `Build`, `ModuleCache.noindex`, `Index.noindex` and
    /// `info.plist`.
    ///
    /// Matched by name and not by kind. `info.plist` and `workspace-state.json` are files
    /// while the rest are directories, and a per-marker type rule would buy nothing here:
    /// none of the four remaining directory names is a word anyone writes by hand, so the
    /// name is what answers "did a build write in here".
    static let buildOutputMarkers: Set<String> = [
        "Build", "ModuleCache.noindex", "Index.noindex", "info.plist",
        "checkouts", "workspace-state.json",
    ]

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
    ///
    /// `public` so that the interface naming a worktree row ("Build output of worktree
    /// feature-sync") reads the worktree's name out of the same prefix this writes it
    /// with. A second spelling of the path in `DevCleanerUI` is a second thing to keep in
    /// step, and the failure would be silent: the row would simply stop being recognised
    /// as a worktree's and fall back to the generic sentence.
    public static let worktreeContainer = ".claude/worktrees"

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
            // The three variable-length lists join the fixed one here rather than being
            // handled apart, so every path they name goes through the same real-directory
            // check, the same de-duplication, the same protection rule and the same single
            // measurement batch as `build` itself.
            //
            // Appended in this order, and the fixed list stays first, so the rows of a
            // project come out in an order that does not depend on what the disk happened
            // to list.
            let relatives = Self.buildFolders
                + Self.cargoTargetFolder(in: project.path, fileManager: context.fileManager)
                + Self.buildVariantFolders(in: project.path, fileManager: context.fileManager)
                + Self.worktreeBuildFolders(in: project.path, fileManager: context.fileManager)
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
            //
            // The **nearest** owner decides, because `protectedRoots` is longest-first and
            // this takes the first match. That now settles which of the two treatments the
            // folder gets, not merely which row it is counted under: an active `example`
            // app inside a pinned plugin is offered, and a folder of the pinned plugin
            // itself is withheld.
            let owner = protectedRoots.first {
                Self.path(candidate.path, isInsideOrEqualTo: $0.path)
            }

            // A pin — anything that is not recent activity — withholds the folder into its
            // project's summary row. `guard case` rather than a lookup of the reason
            // elsewhere: the reason travelling with the root is the only thing that decides.
            if let owner, !Self.isOfferedUnticked(owner.reason) {
                if protectedTotals[owner.path] == nil { protectedOrder.append(owner.path) }
                protectedTotals[owner.path, default: 0] += size
                continue
            }

            items.append(ScanHelpers.item(
                scannerID: id, group: group, path: candidate.path,
                name: candidate.relative,
                // The project's name, and — when something is holding the row back — the
                // reason as well, through the same `detail(for:)` a summary row uses. The
                // deck and `devcleaner scan` have nowhere else to put it: they show one
                // line per folder, and "946 MB .build (Sample Game)" with an empty tick box
                // beside it says nothing about why the box is empty.
                detail: Self.detail(of: candidate.project, heldBackBy: owner?.reason),
                sizeBytes: size,
                // When the **project** last changed, not when this folder did. The
                // answer already exists: `CleanerService` asks `ActivityInspector` for
                // it to resolve protection, and it used to stop there. Carried here so
                // an interface can say "last changed 4 months ago" beside the project
                // without walking it a second time and reaching a second answer.
                //
                // Every folder of one project therefore reads the same date, which is
                // right: it is a fact about the project. A folder's own timestamp
                // would say when the build last ran, which is the opposite of what the
                // user is being asked to judge.
                lastUsed: context.activity[candidate.project.path],
                risk: Self.networkRestored.contains(candidate.relative) ? .elevated : .safe,
                // Unticked for either of two reasons, and they are not the same reason.
                // `du` could not size it, or the project is one the user is working in.
                // Both leave the row out of a default clean; only the second is worth
                // printing, so only the second sets `untickedReason` — which is what makes
                // "unticked because unmeasured" still tellable apart downstream.
                startsUnticked: measurement.unmeasured || owner != nil,
                untickedReason: owner?.reason))
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

    /// The build folders of every worktree under `.claude/worktrees`, as paths relative
    /// to the project — the same shape as `buildFolders`, so the caller treats them
    /// identically and the row is named `.claude/worktrees/<name>/build`.
    ///
    /// Both spellings per worktree. A worktree of a Swift package builds into `.build`
    /// and never into `build`, so offering only the second name leaves the largest folder
    /// in an agent's worktree invisible — the same hole this function was written to
    /// close, one letter along.
    ///
    /// Only the worktree directories are listed here; whether each build folder is a real
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
            .flatMap { ["\(worktreeContainer)/\($0.name)/build",
                        "\(worktreeContainer)/\($0.name)/.build"] }
    }

    /// The `.build-…` folders of a project that really hold build output, as paths
    /// relative to it — again the same shape as `buildFolders`.
    ///
    /// The only place in this scanner that decides from a folder's **contents** rather
    /// than its name, and `buildOutputMarkers` says why. The rule stays "a fixed list,
    /// never a walk for what looks big": this walk is one level deep, over names that
    /// already begin with `.build-`, and what it looks for is a fixed list too.
    ///
    /// Listed with `contentsOfDirectory` rather than `ScanHelpers.children`, which drops
    /// every dot-entry — and every name wanted here begins with one.
    ///
    /// Sorted by name, for the same reason the worktrees are.
    static func buildVariantFolders(in projectPath: String, fileManager: FileManager) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: projectPath)
        else { return [] }
        return names
            .filter { $0.hasPrefix(buildVariantPrefix) }
            .filter {
                holdsBuildOutput(
                    (projectPath as NSString).appendingPathComponent($0),
                    fileManager: fileManager)
            }
            .sorted()
    }

    /// A real directory with at least one `buildOutputMarkers` entry directly inside it.
    ///
    /// The real-directory check repeats the shared one in `scan`, which would refuse a
    /// plain file or a symlink whatever this answered. Repeated deliberately: a symlink
    /// pointing at somebody else's build output really does hold the markers, so this
    /// function saying yes to one would leave "it is not offered" resting entirely on a
    /// guard three call frames away. The same reason a project root is both an allowed
    /// root and a forbidden target in `PathGuard.forRun`.
    static func holdsBuildOutput(_ path: String, fileManager: FileManager) -> Bool {
        guard isRealDirectory(path, fileManager: fileManager),
              let entries = try? fileManager.contentsOfDirectory(atPath: path)
        else { return false }
        return entries.contains { buildOutputMarkers.contains($0) }
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

    /// Whether a protection reason offers the folder unticked rather than withholding it.
    ///
    /// Exactly `.recentActivity`, and exhaustive with no `default` so that the next reason
    /// to reach `ProtectionSet.projects` has to be decided here rather than defaulting into
    /// the offering branch. Defaulting the wrong way is not symmetric: withhold a folder
    /// that could have been offered and the user loses a card, offer one that should have
    /// been withheld and the user loses a folder.
    ///
    /// `.pinnedProject` is the one that matters today. A pin is the user saying no by hand,
    /// and no amount of "but the deck asks first" makes it a yes.
    static func isOfferedUnticked(_ reason: ProtectionReason) -> Bool {
        switch reason {
        case .recentActivity:
            return true
        case .pinnedProject,
             .mostRecentlyUsedDevice, .recentlyUsedDevice, .pinnedDevice, .bootedDevice,
             .sdkInUse, .newestRuntime, .runtimeUsedByKeptDevice,
             .runtimeUsedByProtectedDevice, .runtimeImageNotDeletable,
             .gradleVersionInUse, .newestDeviceSupport:
            return false
        }
    }

    /// The text beside a per-folder row: the project it belongs to, and the reason it is
    /// being held back when something is holding it back.
    ///
    /// One string rather than two fields because `CleanupItem.detail` is one line and every
    /// listing in the app prints it as one. The reason goes through `detail(for:)`, the same
    /// function a summary row uses, so the two routes into the user's eyes cannot start
    /// wording the same fact differently.
    ///
    /// The project named is the folder's **own** project, not the owner's, which can differ
    /// when one project sits inside another. The folder is what is being offered and its own
    /// project is what the user recognises; the reason beside it is the owner's, which for
    /// recent activity is true of the inner project as well — `ActivityInspector` walks the
    /// whole tree, so a project inside an active one is almost always active itself.
    static func detail(
        of project: DiscoveredProject, heldBackBy reason: ProtectionReason?
    ) -> String {
        guard let reason else { return project.name }
        return "\(project.name) · \(detail(for: reason))"
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
             .runtimeUsedByProtectedDevice, .runtimeImageNotDeletable,
             .gradleVersionInUse, .newestDeviceSupport:
            // None of these reach `ProtectionSet.projects` today — they belong to
            // devices, SDKs, runtimes and device support folders. Should one arrive, the
            // reason's own words are the only text guaranteed not to lie about it.
            return reason.description
        }
    }
}
