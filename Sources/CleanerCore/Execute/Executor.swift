import Foundation

public enum ItemOutcome: String, Codable, Sendable {
    /// Moved to the Trash and restorable until the Trash is emptied.
    case trashed
    /// Gone for good. Simulators, runtimes and emulators always land here — the tools
    /// that remove them have no Trash equivalent.
    case deleted
    case failed
    case skipped
}

public struct RunEntry: Codable, Sendable, Equatable {
    public let itemID: String
    public let name: String
    public let target: String
    public let sizeBytes: Int64
    public let outcome: ItemOutcome
    /// Where it now lives in the Trash. Non-nil only for `.trashed`.
    public let trashedTo: String?
    public let reason: String?

    public init(itemID: String, name: String, target: String, sizeBytes: Int64,
                outcome: ItemOutcome, trashedTo: String? = nil, reason: String? = nil) {
        self.itemID = itemID
        self.name = name
        self.target = target
        self.sizeBytes = sizeBytes
        self.outcome = outcome
        self.trashedTo = trashedTo
        self.reason = reason
    }

    /// Whether this can still be got back. Only a trashed item can.
    ///
    /// `.deleted` means unrecoverable, and it is where every simulator, runtime and
    /// emulator lands whatever `moveToTrash` is set to: `simctl delete`,
    /// `simctl runtime delete` and `avdmanager delete avd` remove outright and there is
    /// no Trash to drag a device back out of. Tasks 19 and 20 warn from this.
    public var isRestorable: Bool { outcome == .trashed }

    /// Hand-written so an entry written by a different build of the app still loads.
    ///
    /// Synthesised decoding turns a missing non-optional key into `DecodingError
    /// .keyNotFound`, `RunLog.load` swallows that with `try?`, and the entry vanishes —
    /// taking `trashedTo` with it, which is the only record of where a trashed item can
    /// be dragged back from. Losing it turns a recoverable delete into a permanent one
    /// from the user's side. `Settings` and `CleanupItem` were both fixed this way after
    /// exactly that bug; this starts there.
    ///
    /// **A field added later must be read with `decodeIfPresent(...) ?? <default>`, never
    /// `decode`.** `aRunEntryWithOnlyItsIdentifyingKeysDecodesToDefaults` in
    /// `RunLogTests` fails the moment one is not.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The four that say what happened to what. An entry missing any of them names
        // nothing and is not worth keeping; `RunRecord` drops it and keeps the rest.
        itemID = try container.decode(String.self, forKey: .itemID)
        name = try container.decode(String.self, forKey: .name)
        target = try container.decode(String.self, forKey: .target)
        outcome = try container.decode(ItemOutcome.self, forKey: .outcome)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        trashedTo = try container.decodeIfPresent(String.self, forKey: .trashedTo)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// One element of `RunRecord.entries`, decoded so that a single unreadable entry costs
/// that entry alone instead of the whole run.
///
/// Without this, one entry whose `outcome` is a case this build does not have — a log
/// written by a newer version, read by an older one — discards every other entry in the
/// same run, including their `trashedTo` paths. Swallowing the error here still advances
/// the unkeyed container, which a bare `try?` around `decode([RunEntry].self)` would not.
private struct LenientRunEntry: Decodable {
    let entry: RunEntry?

    init(from decoder: any Decoder) throws {
        entry = try? RunEntry(from: decoder)
    }
}

public struct RunRecord: Codable, Sendable, Equatable {
    public let startedAt: Date
    public let finishedAt: Date
    public let availableBytesBefore: Int64
    public let availableBytesAfter: Int64
    public let entries: [RunEntry]
    /// Things worth telling the user that are not per-item outcomes, such as Xcode
    /// having been open during the run, or a device having been removed permanently.
    public let notes: [String]

    public init(startedAt: Date, finishedAt: Date, availableBytesBefore: Int64,
                availableBytesAfter: Int64, entries: [RunEntry], notes: [String] = []) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.availableBytesBefore = availableBytesBefore
        self.availableBytesAfter = availableBytesAfter
        self.entries = entries
        self.notes = notes
    }

    /// Measured change in free space. In Trash mode this is near zero, because
    /// trashing moves bytes rather than releasing them. Never present this as
    /// "freed" alongside a large trashed total — report both, separately.
    public var freeSpaceChangeBytes: Int64 { availableBytesAfter - availableBytesBefore }

    public var trashedBytes: Int64 {
        entries.filter { $0.outcome == .trashed }.reduce(0) { $0 + $1.sizeBytes }
    }
    public var permanentlyDeletedBytes: Int64 {
        entries.filter { $0.outcome == .deleted }.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Everything that cannot be got back. This is the list Tasks 19 and 20 have to
    /// show as permanent; the Trash holds nothing for any of it.
    public var permanentlyDeletedEntries: [RunEntry] {
        entries.filter { $0.outcome == .deleted }
    }

    /// Rows the run deliberately stood aside from, each carrying the reason to act on.
    ///
    /// An emulator lands here when `adb` cannot be reached at all, and the interface must
    /// show `RunEntry.reason` beside the row rather than a bare "skipped". The reason names
    /// the `adb` path and what went wrong, so the user can install `platform-tools` or
    /// start the adb server and run again; without it, the emulator rows look like they
    /// silently did nothing and there is nothing to fix.
    public var skippedEntries: [RunEntry] {
        entries.filter { $0.outcome == .skipped }
    }

    /// Rows that were attempted and refused or errored, each carrying its reason.
    public var failedEntries: [RunEntry] {
        entries.filter { $0.outcome == .failed }
    }

    /// One line per row that did not get removed, ready to show. Skipped first, because a
    /// skipped row is the one the user can usually fix and retry.
    public var unfinishedReasons: [String] {
        (skippedEntries + failedEntries).map { entry in
            "\(entry.name): \(entry.reason ?? "no reason given")"
        }
    }

    /// Hand-written for the same reason as `RunEntry.init(from:)`, one level up.
    ///
    /// `notes` is the newest field here, and it is where "these devices are gone for
    /// good" is recorded. A stored run written before it existed must still load rather
    /// than be discarded whole; `aLogFileMissingTheNewestFieldStillLoadsTheRun` pins that,
    /// and `aRunRecordWithOnlyAStartTimeDecodesToDefaults` pins the general shape so the
    /// next field added cannot repeat the bug.
    ///
    /// `startedAt` is the one key with no sensible fallback: it is what identifies the run
    /// and what the file is named after, so a document without it is not a run record.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt) ?? startedAt

        // Read together on purpose. One reading without the other would make
        // `freeSpaceChangeBytes` the whole of the other one — "freed 480 GB" from a file
        // that only lost a key. Unknown has to read as no measured change.
        let before = try container.decodeIfPresent(Int64.self, forKey: .availableBytesBefore)
        let after = try container.decodeIfPresent(Int64.self, forKey: .availableBytesAfter)
        availableBytesBefore = before ?? after ?? 0
        availableBytesAfter = after ?? before ?? 0

        entries = (try container.decodeIfPresent([LenientRunEntry].self, forKey: .entries) ?? [])
            .compactMap(\.entry)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    public var trashedCount: Int { entries.filter { $0.outcome == .trashed }.count }
    public var deletedCount: Int { entries.filter { $0.outcome == .deleted }.count }
    public var failedCount: Int { entries.filter { $0.outcome == .failed }.count }
    public var skippedCount: Int { entries.filter { $0.outcome == .skipped }.count }
}

public struct ExecutionProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let currentName: String

    public init(completed: Int, total: Int, currentName: String) {
        self.completed = completed
        self.total = total
        self.currentName = currentName
    }
}

extension PathGuard {
    /// Where the Executor is allowed to delete, one entry per location a committed
    /// scanner can actually produce.
    ///
    /// Each entry is the **narrowest directory that strictly contains** every path the
    /// scanner named beside it emits. Strictly, because `validate` refuses a path that
    /// is equal to a root, so a root can never be the item itself. Narrowest, because a
    /// root is a licence to delete: `~/Library/Developer` would also cover
    /// `Xcode/UserData` (your snippets, breakpoints and key bindings) and
    /// `~/.android` would also cover `adbkey` and `debug.keystore`, and no scanner
    /// produces any of those.
    ///
    /// **Adding a location to a scanner means adding its root here**, or the row is
    /// refused after the user ticks it and the app silently frees nothing.
    static let runRelativeRoots = [
        "Library/Developer/Xcode/DerivedData",       // xcode.derivedData
        "Library/Developer/Xcode/Archives",          // xcode.archives (two levels down)
        "Library/Developer/Xcode/iOS DeviceSupport", // xcode.deviceSupport
        "Library/Developer/Xcode/watchOS DeviceSupport", // xcode.deviceSupport
        "Library/Developer/CoreSimulator",           // ios.simulatorCaches -> .../Caches
        // other.cocoapods (Caches/CocoaPods), other.jsPackages (Caches/Yarn) and
        // other.libraryCaches, which reads a fixed allowlist of direct children.
        "Library/Caches",
        "Library/pnpm",                              // other.jsPackages -> pnpm/store
        ".gradle",                                   // android.gradle; `daemon` is a direct child
        ".android/avd",                              // android.avds, avdmanager-missing fallback
        ".pub-cache",                                // flutter.pubCache -> hosted, git
        "fvm/versions",                              // flutter.fvm; keeps `~/fvm/default` out
        ".fvm/versions",                             // flutter.fvm, older install layout
        ".npm",                                      // other.jsPackages -> .npm/_cacache
        ".cocoapods",                                // other.cocoapods -> .cocoapods/repos
        ".bun/install",                              // other.jsPackages -> .bun/install/cache
    ]

    /// Single paths the run may delete without their parent becoming a root.
    ///
    /// `flutter.fvm` offers `~/fvm/cache.git`, fvm's bare clone of the Flutter
    /// repository. Its only containing directory is `~/fvm`, which also holds `default` —
    /// the symlink the `flutter` command on PATH resolves through — so making `~/fvm` a
    /// root would hand the run a licence over that link as well. `fvm/versions` above
    /// stays exactly as narrow as Task 17 made it; this adds the one further path and
    /// nothing around it.
    static let runRelativeExactPaths = [
        "fvm/cache.git",                             // flutter.fvm mirror
        ".fvm/cache.git",                            // flutter.fvm mirror, older layout
        ".android/cache",                            // other.localToolCaches
        ".android/build-cache",                      // other.localToolCaches
        ".dartServer",                               // other.localToolCaches
    ]

    /// The guard for one clean, per spec §7.2 rule 1.
    ///
    /// `projectPaths` must be **every** discovered project directory, not only the
    /// protected ones. `ProjectBuildOutputScanner` gives a protected project a summary
    /// row whose deletion target is the project's own directory, and registering the
    /// directory as forbidden is the third of the three independent things that keep
    /// that row harmless. `theProtectedSummaryRowNamesTheProjectAndIsRefusedByPathGuard`
    /// in `ProjectScannerTests` pins the contract from the scanner's side.
    ///
    /// `androidSDKPath` defaults to the standard location. Pass the same value the
    /// `ScanContext` was built with, or system images installed elsewhere are refused.
    public static func forRun(
        home: String, projectRoots: [String], projectPaths: [String],
        androidSDKPath: String? = nil
    ) -> PathGuard {
        var roots = runRelativeRoots.map { (home as NSString).appendingPathComponent($0) }

        let sdk = androidSDKPath
            ?? (home as NSString).appendingPathComponent("Library/Android/sdk")
        // android.systemImages, at <sdk>/system-images/<api>/<variant>/<abi>. Narrower
        // than the SDK root, which also holds platform-tools and the licences.
        roots.append((sdk as NSString).appendingPathComponent("system-images"))
        // android.ndk, at <sdk>/ndk/<version>. Its own root, so `platform-tools`,
        // `licenses` and the rest of the SDK stay out of reach. Without this every NDK
        // row is refused after the user ticks it and the run frees nothing.
        roots.append((sdk as NSString).appendingPathComponent("ndk"))

        // projects.buildOutput. The roots the user declared, so nothing outside the
        // directories they named as holding code can be touched at all. This also covers
        // `<project>/.claude/worktrees/<name>/build`, which is inside a project.
        //
        // A root that is too wide is dropped from the **allowed** side, whatever the
        // settings say. `/` as a project root lets the guard through to `/System/Library`,
        // the home directory lets it through to `~/Library/Mail`, `/Users` — home's parent
        // — lets it through to both plus `/Users/Shared`, and a relative root such as `.`
        // or `dev` means whatever the process working directory happens to be. In every
        // case the only rule left would be that the root itself is a forbidden target.
        // `SettingsStore.load()` accepts a hand-edited `settings.json` without validating
        // it, so a check in the interface cannot be the only one and this is the last
        // place that can refuse the value.
        //
        // One rule, shared with `SettingsStore.save`, so the value the settings screen
        // refuses and the value the guard refuses cannot drift apart. An entry that does
        // not resolve is kept here and dropped by `PathGuard.init`, which cannot
        // canonicalise it either, so nothing else changes.
        //
        // Every dropped root stays in `forbiddenTargets` below — dropping a root from the
        // allowed side must never be what makes something deletable.
        roots.append(contentsOf: projectRoots.filter {
            !SettingsStore.isTooWideForAProjectRoot($0, home: home)
        })

        return PathGuard(
            allowedRoots: roots,
            // A project root is both an allowed root and a forbidden target: delete
            // inside `~/dev`, never `~/dev` itself. `validate` already refuses a path
            // equal to a root; this is the second, independent statement of it.
            forbiddenTargets: projectRoots + projectPaths,
            allowedExactPaths: runRelativeExactPaths.map {
                (home as NSString).appendingPathComponent($0)
            })
    }
}

// @unchecked because of the stored FileManager — see Global Constraints.
public struct Executor: @unchecked Sendable {
    /// Sentences the run record carries that are not about a single item. Named
    /// constants so Tasks 19 and 20 match on a symbol rather than on prose.
    public enum Note {
        public static let xcodeWasOpen =
            "Xcode was open during this run; it will rebuild its derived data."
        /// Spec §7.3. Devices ignore `moveToTrash` because the tools that remove them
        /// have no Trash equivalent, so the record has to say so in the user's words.
        public static let devicesWereRemovedPermanently =
            "Simulators, runtimes and emulators were removed outright. "
            + "They are not in the Trash and cannot be restored."
        /// Spec §8.2: cancelling stops before the next item, and what is already gone is
        /// gone. The report has to say which run this was, or a short list of entries
        /// looks like a run that found almost nothing to do.
        public static let runWasCancelled =
            "You cancelled this run. Everything already removed stays removed; "
            + "the rest was left alone."
    }

    /// The reason written on every row a cancelled run did not reach.
    ///
    /// Lower case and a full clause, matching the other `RunEntry.reason` strings, because
    /// `RunRecord.unfinishedReasons` prints them as "\(name): \(reason)".
    public static let cancelledReason =
        "you cancelled the run before this item, so nothing was attempted for it"

    private let pathGuard: PathGuard
    private let runner: any ProcessRunner
    private let remover: any FileRemoving
    private let fileManager: FileManager
    private let home: String
    private let moveToTrash: Bool
    private let androidSDKPath: String
    /// The clock, injected. Production code never reads the wall clock directly — every
    /// scanner takes `context.now` and this is the Executor's equivalent, so
    /// `finishedAt` is pinned by a test instead of being unassertable.
    private let now: @Sendable () -> Date

    public init(guard pathGuard: PathGuard, runner: any ProcessRunner,
                remover: any FileRemoving = SystemFileRemover(),
                fileManager: FileManager = .default,
                home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                moveToTrash: Bool = true,
                androidSDKPath: String? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.pathGuard = pathGuard
        self.runner = runner
        self.remover = remover
        self.fileManager = fileManager
        self.home = home
        self.moveToTrash = moveToTrash
        self.androidSDKPath = androidSDKPath
            ?? (home as NSString).appendingPathComponent("Library/Android/sdk")
        self.now = now
    }

    private var adbPath: String {
        (androidSDKPath as NSString).appendingPathComponent("platform-tools/adb")
    }

    private var avdManagerPath: String {
        (androidSDKPath as NSString).appendingPathComponent("cmdline-tools/latest/bin/avdmanager")
    }

    /// `isCancelled` is asked **before each item**, and a `true` answer stops the run
    /// there: spec §8.2. It is a parameter rather than a bare `Task.isCancelled` read for
    /// two reasons. The loop below is synchronous — `perform` never suspends — so nothing
    /// in the runtime would notice a cancellation on its own. And a test has to be able to
    /// say exactly when the flag flips; racing a real `Task.cancel()` against a
    /// synchronous loop is a test that passes on an idle machine and fails on a busy one.
    /// The default is the real thing, so `CleanerService.clean` is unchanged and the menu
    /// bar app's `task.cancel()` works.
    public func run(
        items: [CleanupItem],
        devices: DeviceInventory,
        startedAt: Date,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        progress: @Sendable (ExecutionProgress) -> Void
    ) async -> RunRecord {
        let before = (try? FreeSpace.availableBytes(forVolumeContaining: home)) ?? 0

        // Asked here as well as before each item, because everything between this line and
        // the loop shells out: `preflight` kills the Gradle daemons and asks `adb` which
        // emulators are running, and `isXcodeRunning` runs `pgrep`. A user who pressed
        // Cancel before the run's task got going must not lose their daemons — and a rebuilt
        // Gradle cache — for a run that is going to delete nothing.
        var cancelled = isCancelled()

        // Preflight looks only at what is actually going to be executed. A protected
        // item is refused below, so it must not cause the Gradle daemons to be killed
        // on its behalf.
        let executable = items.filter(\.isDeletable)
        let emulators: RunningEmulators = cancelled ? .known([]) : preflight(items: executable)

        // The second of the two layers that keep a running simulator alive. The first is
        // `ProtectionResolver`, which never offers one; this one refuses it even if a
        // caller hands it over anyway, exactly as the `.deleteAVD` case refuses an
        // emulator `adb` says is running. `simctl delete` destroys the device directory
        // and everything installed in it, with no Trash and no undo, so one layer is not
        // enough.
        let booted = Set(devices.simulators.filter(\.isBooted).map(\.udid))

        var notes: [String] = []
        if !cancelled, isXcodeRunning() { notes.append(Note.xcodeWasOpen) }

        var entries: [RunEntry] = []
        for (index, item) in items.enumerated() {
            // Sticky: once the user has cancelled, every remaining row is skipped, and
            // the flag is not asked again. Asking again would let a caller whose closure
            // flickers resume a run the user stopped.
            if cancelled || isCancelled() {
                cancelled = true
                entries.append(RunEntry(
                    itemID: item.id, name: item.name, target: Self.target(of: item.method),
                    sizeBytes: item.sizeBytes, outcome: .skipped,
                    reason: Self.cancelledReason))
            } else {
                entries.append(perform(item, emulators: emulators, bootedSimulators: booted))
            }
            // Reported for a skipped row too, so the counter the popover shows still
            // reaches its total instead of stopping part way with no explanation.
            progress(ExecutionProgress(
                completed: index + 1, total: items.count, currentName: item.name))
        }
        if cancelled { notes.append(Note.runWasCancelled) }

        // `method.path` is nil exactly for the three device cases, and `.deleted` is
        // the only outcome that cannot be undone.
        let removedADevice = zip(items, entries).contains { item, entry in
            item.method.path == nil && entry.outcome == .deleted
        }
        if removedADevice { notes.append(Note.devicesWereRemovedPermanently) }

        let after = (try? FreeSpace.availableBytes(forVolumeContaining: home)) ?? 0
        return RunRecord(
            startedAt: startedAt, finishedAt: now(),
            availableBytesBefore: before, availableBytesAfter: after,
            entries: entries, notes: notes)
    }

    /// Xcode being open does not stop the run — derived data is regenerated —
    /// but it belongs in the report so a slow next build is not a surprise.
    private func isXcodeRunning() -> Bool {
        guard let result = try? runner.run("/usr/bin/pgrep", ["-x", "Xcode"]) else { return false }
        return result.succeeded
            && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: preflight

    /// What the run was able to learn about emulators that are running now.
    ///
    /// The two cases must never be collapsed into one empty set. `.known([])` means adb
    /// answered and nothing is running, so an AVD can be deleted. `.unknown` means adb
    /// could not be asked or would not answer — `platform-tools` missing, or its server
    /// failing to start — and then a running emulator cannot be ruled out. Deleting one
    /// anyway is unrecoverable: `avdmanager delete avd` has no Trash and no undo.
    private enum RunningEmulators {
        case known(Set<String>)
        /// Why adb could not answer, in words the user can act on and then retry.
        case unknown(String)
    }

    /// Returns which AVDs are running and must be skipped, or why that is not known.
    ///
    /// **Nothing here shuts a simulator down.** Until this fix wave the run began by
    /// sending `simctl shutdown` to every booted simulator it was about to delete, which
    /// killed a live session with no warning and then destroyed the device. A booted
    /// simulator is now protected by the resolver and refused by `perform`, so a shutdown
    /// could only ever precede a deletion that is not going to happen: it would end the
    /// user's session and free nothing. It is gone rather than reordered.
    private func preflight(items: [CleanupItem]) -> RunningEmulators {
        // Spec §7.1 rule 3: the daemons hold `~/.gradle/caches` open, so they stop
        // before anything under it is touched.
        if items.contains(where: { $0.scannerID == "android.gradle" }) {
            stopGradleDaemons()
        }
        guard items.contains(where: { if case .deleteAVD = $0.method { return true }; return false })
        else { return .known([]) }
        return runningEmulators()
    }

    private func stopGradleDaemons() {
        _ = try? runner.run("/usr/bin/pkill", ["-f", "GradleDaemon"])
    }

    private func runningEmulators() -> RunningEmulators {
        let listing: ProcessResult
        do {
            listing = try runner.run(adbPath, ["devices"])
        } catch {
            // A missing `platform-tools` lands here rather than in the exit-code branch:
            // there is no binary to start, so running it throws.
            return .unknown("adb could not be run at \(adbPath) (\(error.localizedDescription))")
        }
        guard listing.succeeded else {
            // adb was there but could not answer — most often its server failed to start.
            let detail = listing.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unknown("adb at \(adbPath) exited with code \(listing.exitCode)"
                + (detail.isEmpty ? "" : ": \(detail)"))
        }

        var names: Set<String> = []
        for line in listing.stdout.split(separator: "\n") {
            let serial = line.split(separator: "\t").first.map(String.init) ?? ""
            // Only emulator serials. A physical phone answers `adb devices` too, its
            // serial is a hardware id, and `emu avd name` is meaningless for it.
            guard serial.hasPrefix("emulator-") else { continue }
            // adb prints the AVD name, then a line containing OK.
            guard let answer = try? runner.run(adbPath, ["-s", serial, "emu", "avd", "name"]),
                  answer.succeeded,
                  let name = answer.stdout.split(separator: "\n").first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else {
                // Something is running and adb will not say which AVD it is. Passing over
                // this serial would leave exactly that AVD deletable underneath it.
                return .unknown("adb at \(adbPath) did not say which AVD \(serial) is running")
            }
            names.insert(name)
        }
        return .known(names)
    }

    // MARK: deletion

    /// The thing a method acts on, for the record. Exhaustive with no `default`, so a
    /// new `DeletionMethod` case stops the build here rather than being logged as "".
    private static func target(of method: DeletionMethod) -> String {
        switch method {
        case .removePath(let path):                 return path
        case .deleteSimulator(let udid):            return udid
        case .deleteSimulatorRuntime(let identifier): return identifier
        case .deleteAVD(let name):                  return name
        }
    }

    private func perform(
        _ item: CleanupItem, emulators: RunningEmulators, bootedSimulators: Set<String>
    ) -> RunEntry {
        func entry(_ outcome: ItemOutcome, target: String,
                   trashedTo: String? = nil, reason: String? = nil) -> RunEntry {
            RunEntry(itemID: item.id, name: item.name, target: target,
                     sizeBytes: item.sizeBytes, outcome: outcome,
                     trashedTo: trashedTo, reason: reason)
        }

        // A protected item reaching here is a bug upstream — the UI never ticks one and
        // the caller passes only what the user selected. It is refused anyway, before
        // anything is resolved or run, because the cost of the bug is a permanently
        // deleted device or a live project's build folder.
        if let protection = item.protection {
            return entry(.failed, target: Self.target(of: item.method),
                         reason: "refused: it is protected (\(protection))")
        }

        switch item.method {
        case .removePath(let path):
            let approved: String
            do {
                approved = try pathGuard.validate(path)
            } catch {
                return entry(.failed, target: path, reason: String(describing: error))
            }
            do {
                // Act on the path the guard approved, never the caller's string —
                // that is what keeps the checked thing and the removed thing the same.
                // Neither trash nor remove follows a symlink; a link moves as a link.
                if moveToTrash {
                    let location = try remover.trash(approved)
                    return entry(.trashed, target: approved, trashedTo: location)
                }
                try remover.remove(approved)
                return entry(.deleted, target: approved)
            } catch {
                return entry(.failed, target: approved, reason: error.localizedDescription)
            }

        // The two simctl cases below always report `.deleted`, never `.trashed`.
        // simctl removes outright and has no Trash equivalent, so `moveToTrash` cannot
        // apply to them however it is set.
        case .deleteSimulator(let udid):
            // The same refusal as a running emulator two cases below, and for the same
            // reason: the user is working in it right now, and `simctl delete` removes the
            // device directory — every installed app, its databases, its user defaults —
            // with no Trash and no undo. `.skipped` rather than `.failed`, because nothing
            // was attempted and nothing about the item is wrong.
            guard !bootedSimulators.contains(udid) else {
                return entry(.skipped, target: udid,
                             reason: "the simulator is running; deleting one cannot be "
                                 + "undone, so it was left alone")
            }
            let result = try? runner.run("/usr/bin/xcrun", ["simctl", "delete", udid])
            return (result?.succeeded ?? false)
                ? entry(.deleted, target: udid)
                : entry(.failed, target: udid, reason: result?.stderr ?? "simctl delete failed")

        case .deleteSimulatorRuntime(let identifier):
            let result = try? runner.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", identifier])
            return (result?.succeeded ?? false)
                ? entry(.deleted, target: identifier)
                : entry(.failed, target: identifier,
                        reason: result?.stderr ?? "simctl runtime delete failed")

        case .deleteAVD(let name):
            switch emulators {
            case .unknown(let cause):
                // Not knowing is treated the same as knowing it is running, and for the
                // same reason: removing an emulator cannot be undone. `.skipped` rather
                // than `.failed` because nothing was attempted and nothing about this
                // item is wrong — the reason names what to fix so the user can run again.
                return entry(.skipped, target: name,
                             reason: "\(cause), so it is not known whether this emulator "
                                 + "is running; removing one cannot be undone, "
                                 + "so it was left alone")
            case .known(let running):
                guard !running.contains(name) else {
                    return entry(.skipped, target: name, reason: "the emulator is running")
                }
            }
            if fileManager.isExecutableFile(atPath: avdManagerPath) {
                let result = try? runner.run(avdManagerPath, ["delete", "avd", "-n", name])
                // `avdmanager delete avd` is permanent — no Trash, whatever
                // `moveToTrash` says.
                if result?.succeeded ?? false { return entry(.deleted, target: name) }
                return entry(.failed, target: name,
                             reason: result?.stderr ?? "avdmanager delete failed")
            }
            let removal = removeAVDFiles(named: name)
            switch removal {
            case .failure(let reason):
                return entry(.failed, target: name, reason: reason)
            // The fallback really does move files to the Trash, so it says so. The
            // "devices are always permanent" rule is about `avdmanager delete avd`,
            // `simctl delete` and `simctl runtime delete`, which have no Trash to use;
            // reporting `.deleted` here would tell the user something is gone for good
            // while it is sitting in their Trash, and they would stop looking for it.
            case .trashed(let landed):
                return entry(.trashed, target: name, trashedTo: landed)
            case .deleted:
                return entry(.deleted, target: name)
            }
        }
    }

    private enum AVDFileRemoval {
        case trashed(String?)
        case deleted
        case failure(String)
    }

    /// Removes the pair of files that make up an AVD, each checked by the guard.
    ///
    /// Only reached when the Android command line tools are missing, so `avdmanager`
    /// cannot be asked. Unlike `avdmanager`, this touches plain files, so it honours
    /// `moveToTrash`.
    private func removeAVDFiles(named name: String) -> AVDFileRemoval {
        let base = (home as NSString).appendingPathComponent(".android/avd")
        let directory = (base as NSString).appendingPathComponent("\(name).avd")
        let ini = (base as NSString).appendingPathComponent("\(name).ini")
        do {
            var removedAny = false
            var landed: String?
            for path in [directory, ini] where fileManager.fileExists(atPath: path) {
                let approved = try pathGuard.validate(path)
                if moveToTrash {
                    let location = try remover.trash(approved)
                    if path == directory { landed = location }
                } else {
                    try remover.remove(approved)
                }
                removedAny = true
            }
            guard removedAny else {
                return .failure("no emulator named \(name) is installed")
            }
            return moveToTrash ? .trashed(landed) : .deleted
        } catch {
            return .failure(String(describing: error))
        }
    }
}
