import Foundation

/// The composition root: the one place that knows how the parts fit together.
///
/// The menu bar app and the command line tool both talk to this and to nothing else. Every
/// other type in this package is reachable from here and none of them is meant to be wired
/// up a second time somewhere else — two wirings mean two answers to "what is protected",
/// and the one the user reads in settings would not be the one that decides what is
/// trashed.
///
/// Nothing here reads the wall clock. `scan` and `clean` are given the time they should
/// treat as now, exactly as every scanner is given `ScanContext.now`, so a test can pin it.
/// The single exception is the `clock` the initialiser defaults, which the `Executor` uses
/// to stamp when a run finished — the same argument, and the same default, that `Executor`
/// has taken since Task 17.
///
// @unchecked because of the stored FileManager — see Global Constraints.
public struct CleanerService: @unchecked Sendable {
    /// Sentences to show **before** a run, as named constants so callers match on a symbol
    /// rather than on prose.
    public enum Warning {
        /// Spec §7.3. `simctl delete`, `simctl runtime delete` and `avdmanager delete avd`
        /// remove outright: there is no Trash to drag a device back out of and no undo,
        /// whatever `Settings.moveToTrash` says.
        ///
        /// "Normally", not "always", and the word is load-bearing. One path really does
        /// use the Trash: when the Android command line tools are missing, `avdmanager`
        /// cannot be asked, and the executor moves the emulator's two files to the Trash
        /// itself and reports `.trashed`. Stating the rule as absolute would be a lie on
        /// that machine, and `RunRecord.permanentlyDeletedEntries` is what says afterwards
        /// which rows really were permanent.
        public static let devicesAreRemovedPermanently =
            "Simulators, runtimes and emulators are normally removed permanently. "
            + "They do not go to the Trash and cannot be restored."

        /// Trashing moves bytes; it does not release them. A run that trashed 6.15 GB
        /// changed free space by 60 MB on a real dev machine, because the Trash still held it.
        public static let trashingDoesNotFreeSpaceYet =
            "Items go to the Trash. The space comes back when you empty it."
    }

    /// Added to `RunRecord.notes` when the run itself succeeded but its record could not be
    /// stored. The stored record is the only place `RunEntry.trashedTo` is written down, so
    /// losing it turns a recoverable delete into a permanent one from the user's side.
    public static let runLogNotWritten =
        "This run could not be saved to the history, so the list above is the only record "
        + "of where these items went. "

    private let settingsStore: SettingsStore
    private let runLog: RunLog
    private let runner: any ProcessRunner
    private let remover: any FileRemoving
    private let sizeMeasurer: any SizeMeasuring
    private let fileManager: FileManager
    private let home: String
    private let androidSDKPath: String
    private let clock: @Sendable () -> Date

    public init(
        settingsStore: SettingsStore,
        runLog: RunLog,
        runner: any ProcessRunner = SystemProcessRunner(),
        remover: any FileRemoving = SystemFileRemover(),
        sizeMeasurer: (any SizeMeasuring)? = nil,
        fileManager: FileManager = .default,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        androidSDKPath: String? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settingsStore = settingsStore
        self.runLog = runLog
        self.runner = runner
        self.remover = remover
        self.sizeMeasurer = sizeMeasurer ?? DiskUsageMeasurer(runner: runner)
        self.fileManager = fileManager
        self.home = home
        self.androidSDKPath = androidSDKPath
            ?? (home as NSString).appendingPathComponent("Library/Android/sdk")
        self.clock = clock
    }

    /// Convenience for production use. Creates no directory and reads no file: both
    /// `defaultDirectory()` calls build a URL, and `SettingsStore.load()` answers with
    /// defaults when there is nothing there.
    public static func makeDefault() -> CleanerService {
        CleanerService(
            settingsStore: SettingsStore(directory: SettingsStore.defaultDirectory()),
            runLog: RunLog(directory: RunLog.defaultDirectory()))
    }

    // MARK: - the registry

    /// **Every scanner that exists**, in the order the popover lists them: group by group,
    /// following `GroupID.allCases`.
    ///
    /// This list is the registry, and a scanner missing from it does not run at all. Worse
    /// than that: `Settings.alwaysSkipScannerIDs` stores these identifiers, so dropping or
    /// renaming one silently switches a scanner back on for a user who had switched it off,
    /// and there is nothing in the settings file to say what happened.
    ///
    /// `android.ndk` is the one that shows how easily this goes wrong — it was added to the
    /// package after the plan was written, and the plan's list of fifteen has no room for
    /// it. `everyScannerInTheSourceTreeIsInTheRegistry` in `CleanerServiceTests` reads the
    /// source directory and fails if a `CleanupScanner` exists that is not named here, so
    /// the next one cannot be forgotten the same way.
    public static func allScanners() -> [any CleanupScanner] {
        [
            // Xcode & iOS
            DerivedDataScanner(), ArchivesScanner(), DeviceSupportScanner(),
            SimulatorDevicesScanner(), SimulatorRuntimesScanner(), SimulatorCachesScanner(),
            // Android
            AVDScanner(), SystemImagesScanner(), NDKScanner(), GradleScanner(),
            // Flutter & Dart
            PubCacheScanner(), FVMScanner(),
            // Projects
            ProjectBuildOutputScanner(),
            // Other caches
            CocoaPodsScanner(), JSPackageCacheScanner(), LocalToolCacheScanner(),
            LibraryCachesScanner(),
        ]
    }

    /// The identifiers of `allScanners()`, in the same order. This is the list a settings
    /// screen offers as switches, and the set `Settings.alwaysSkipScannerIDs` draws from.
    public static var scannerIDs: [String] { allScanners().map(\.id) }

    // MARK: - settings

    public func settings() -> Settings { settingsStore.load() }

    /// Stores settings, refusing a project root of `~` or `/` — see `SettingsStore.save`.
    public func save(_ settings: Settings) throws { try settingsStore.save(settings) }

    // MARK: - scanning

    /// A full scan. Takes about 50 seconds on a real dev machine, almost all of it `du`, so
    /// `progress` is offered rather than leaving the caller with nothing to show.
    /// It defaults to doing nothing, so every existing caller is unchanged.
    public func scan(
        now: Date, progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) async -> ScanResult {
        await ScanEngine(scanners: Self.allScanners())
            .scan(context: makeContext(now: now), progress: progress)
    }

    public func protectionSummary(now: Date) async -> ProtectionSet {
        makeContext(now: now).protection
    }

    // MARK: - cleaning

    /// Removes the items it is given and stores the run.
    ///
    /// It removes **what it is handed**, not what it thinks should go. `ScanResult
    /// .defaultSelection` is the list for a default clean; anything else is the user's own
    /// ticking. The executor still refuses a protected item, and `PathGuard` still refuses
    /// a path outside the roots, so a caller that hands over the wrong list loses the
    /// operation rather than the data.
    public func clean(
        items: [CleanupItem], now: Date, progress: @Sendable (ExecutionProgress) -> Void
    ) async -> RunRecord {
        let settings = settingsStore.load()
        let projects = discoverProjects(settings: settings)

        let executor = Executor(
            guard: PathGuard.forRun(
                home: home,
                // Deliberately the settings as written, not `allowedProjectRoots`.
                // `forRun` drops `~` and `/` from the **allowed** side itself and keeps
                // them in `forbiddenTargets`; handing it the filtered list would take
                // them out of the forbidden set too, and dropping a root must never be
                // what makes something deletable.
                projectRoots: settings.projectRoots,
                projectPaths: projects.map(\.path),
                androidSDKPath: androidSDKPath),
            runner: runner, remover: remover, fileManager: fileManager,
            home: home, moveToTrash: settings.moveToTrash,
            // The same SDK the scan used. Without it the executor looks for `adb` and
            // `avdmanager` in the default place on a machine whose SDK is elsewhere, and
            // every emulator row is skipped for a reason that is not the real one.
            androidSDKPath: androidSDKPath,
            now: clock)

        let devices = DeviceInventoryLoader(
            runner: runner, fileManager: fileManager,
            home: home, androidSDKPath: androidSDKPath).load()

        let record = await executor.run(
            items: items, devices: devices, startedAt: now, progress: progress)
        return store(record)
    }

    /// A default clean: removes exactly the rows an interface ticks when the list first
    /// appears, and nothing else.
    ///
    /// This exists so the tick rule is not decided in an executable target. `main.swift`
    /// held `let selected = result.defaultSelection` and handed that to `clean`, and an
    /// executable cannot be imported by a test target — so the single most destructive
    /// decision in the tool was verified only by running the binary and reading the
    /// output. The menu bar app would have had the identical exposure. Here it is an
    /// ordinary method a test calls with a pinned `ScanResult`.
    ///
    /// `defaultSelection`, never `items.filter(\.isDeletable)`. The two spellings were
    /// the same value until `startsUnticked` arrived; the second one puts 5.6 GB of
    /// Android NDK re-download into a clean the user never asked for, and now also every
    /// row whose size could not be measured.
    public func cleanDefault(
        _ result: ScanResult, now: Date, progress: @Sendable (ExecutionProgress) -> Void
    ) async -> RunRecord {
        await clean(items: result.defaultSelection, now: now, progress: progress)
    }

    /// Writes the run and returns it, saying so in the record itself if it could not.
    ///
    /// A failed write never fails the run — the items are already gone — but it must not be
    /// silent either. The stored file holds the only copy of every `RunEntry.trashedTo`,
    /// which is where a trashed item can be dragged back from; if it was not written, the
    /// screen in front of the user is the only record there will ever be.
    private func store(_ record: RunRecord) -> RunRecord {
        do {
            try runLog.write(record)
            return record
        } catch {
            return RunRecord(
                startedAt: record.startedAt, finishedAt: record.finishedAt,
                availableBytesBefore: record.availableBytesBefore,
                availableBytesAfter: record.availableBytesAfter,
                entries: record.entries,
                notes: record.notes + [Self.runLogNotWritten + error.localizedDescription])
        }
    }

    /// The stored runs, newest first. A file that cannot be decoded is left out rather
    /// than taking the rest of the history with it.
    public func recentRuns(limit: Int = RunLog.retainedRuns) -> [RunRecord] {
        runLog.recent(limit: limit).compactMap(runLog.load(at:))
    }

    // MARK: - warnings

    /// What to tell the user **before** a run, given what they have ticked.
    ///
    /// Both sentences are conditional on the selection, so neither becomes wallpaper: the
    /// permanence warning appears only when a device is actually going, and the Trash
    /// sentence only when something goes to the Trash.
    public func warnings(for items: [CleanupItem]) -> [String] {
        Self.warnings(for: items, moveToTrash: settingsStore.load().moveToTrash)
    }

    /// The same rule with the Trash setting supplied, so a caller that already has the
    /// settings does not read the file again.
    public static func warnings(for items: [CleanupItem], moveToTrash: Bool) -> [String] {
        // Only what would really be attempted. A protected row is refused by the executor,
        // so it must not raise a warning about a permanence that will not happen.
        let executable = items.filter(\.isDeletable)
        var warnings: [String] = []
        // `method.path == nil` is exactly the three device cases — see `DeletionMethod.path`.
        if executable.contains(where: { $0.method.path == nil }) {
            warnings.append(Warning.devicesAreRemovedPermanently)
        }
        if moveToTrash, executable.contains(where: { $0.method.path != nil }) {
            warnings.append(Warning.trashingDoesNotFreeSpaceYet)
        }
        return warnings
    }

    // MARK: - the shared context

    private func makeContext(now: Date) -> ScanContext {
        let settings = settingsStore.load()
        let ignoredRoots = settings.projectRoots.filter {
            SettingsStore.isTooWideForAProjectRoot($0, home: home)
        }
        let projects = discoverProjects(settings: settings)

        let inspector = ActivityInspector(runner: runner, fileManager: fileManager)
        var activity: [String: Date] = [:]
        for project in projects {
            activity[project.path] = inspector.lastActivity(of: project)
        }

        let devices = DeviceInventoryLoader(
            runner: runner, fileManager: fileManager,
            home: home, androidSDKPath: androidSDKPath).load()

        let protection = ProtectionResolver(settings: settings, fileManager: fileManager)
            .resolve(projects: projects, activity: activity, devices: devices, now: now)

        return ScanContext(
            settings: settings, protection: protection, projects: projects, devices: devices,
            home: home, androidSDKPath: androidSDKPath,
            sizeMeasurer: sizeMeasurer, runner: runner, fileManager: fileManager, now: now,
            ignoredProjectRoots: ignoredRoots)
    }

    /// The projects under the roots worth walking, each one once.
    ///
    /// Two things happen here that `ProjectDiscovery` does not do for itself.
    ///
    /// A root of `~` or `/` is dropped. `SettingsStore.save` refuses to store one, but
    /// `load()` reads a hand-edited file without validating it, and walking the home
    /// directory four levels deep — then walking every "project" found there for its newest
    /// file — takes minutes and produces a list of the user's Documents folder.
    ///
    /// The result is de-duplicated by path. `discover(roots:)` appends per root and never
    /// de-duplicates, so a user whose roots hold both `~/dev` and `~/dev/app` gets that
    /// project twice: two identical `ActivityInspector` walks of the same tree, and the
    /// same paths measured twice by `du`.
    private func discoverProjects(settings: Settings) -> [DiscoveredProject] {
        let roots = settings.projectRoots.filter {
            !SettingsStore.isTooWideForAProjectRoot($0, home: home)
        }
        var seen: Set<String> = []
        return ProjectDiscovery(fileManager: fileManager)
            .discover(roots: roots)
            .filter { seen.insert($0.path).inserted }
    }
}
