import Foundation

// Everything the command line tool says, and every decision it makes about what the user
// asked for, lives in this file rather than in `main.swift`.
//
// `main.swift` cannot be imported by a test — an executable target is not a module a test
// target can link — so anything written there is only checkable by running the binary, and
// the binary's one dangerous path may not be run at all. Keeping the strings and the
// argument rules here means the tick rule, the three numbers and the destructive gate are
// all ordinary functions a test calls with pinned inputs.

// MARK: - what the user asked for

/// The four commands, plus the two ways an invocation can fail to be one of them.
///
/// A separate case for the dry run rather than a `--dry-run` flag carried alongside
/// `.clean`, because the two differ by whether anything is deleted and a boolean that
/// defaults to "delete" is the wrong shape for that. `CLIParser.parse` never produces
/// `.clean` from an argument list it did not fully understand.
public enum CLIRequest: Equatable, Sendable {
    case scan
    case protect
    /// `clean --dry-run`: prints the exact list and removes nothing.
    case dryRun
    /// `clean`: the only request that can remove anything, and only after the user types
    /// `CleanConfirmation.phrase` at a prompt.
    case clean
    /// No arguments, or an explicit request for help. Exit status 0.
    case usage
    /// Something that is not a command, with the sentence to print. Exit status 64.
    case invalid(String)
}

public enum CLIParser {
    /// Turns the arguments after the program name into a request.
    ///
    /// Unrecognised arguments are refused rather than ignored, and this is a safety rule
    /// rather than tidiness. Testing for the dry run with `arguments.contains("--dry-run")`
    /// makes `devcleaner clean --dryrun` — one missing hyphen — a **real** clean that the
    /// user believed was a rehearsal. Anything this function does not fully understand
    /// becomes `.invalid`, so a typo can only ever cost an error message.
    public static func parse(_ arguments: [String]) -> CLIRequest {
        guard let command = arguments.first else { return .usage }
        let rest = Array(arguments.dropFirst())

        func takingNoOptions(_ request: CLIRequest) -> CLIRequest {
            guard rest.isEmpty else {
                return .invalid("devcleaner \(command) takes no options, "
                    + "but got: \(rest.joined(separator: " "))")
            }
            return request
        }

        switch command {
        case "help", "--help", "-h":
            return takingNoOptions(.usage)
        case "scan":
            return takingNoOptions(.scan)
        case "protect":
            return takingNoOptions(.protect)
        case "clean":
            if rest.isEmpty { return .clean }
            if rest == ["--dry-run"] { return .dryRun }
            return .invalid("devcleaner clean takes only --dry-run, "
                + "but got: \(rest.joined(separator: " ")). "
                + "Nothing was removed.")
        default:
            return .invalid("devcleaner: \(command) is not a command.")
        }
    }
}

/// The gate in front of the only path that removes anything.
///
/// A typed word rather than a `--yes` flag. A flag can be in a shell history, a script or a
/// half-remembered command; typing `clean` is a decision made after reading the list that
/// was just printed. `y`, `yes` and `Y` are all refused on purpose — those are the answers
/// a person gives without reading.
public enum CleanConfirmation {
    /// The exact word, compared after trimming whitespace and case-sensitively.
    public static let phrase = "clean"

    public static let prompt =
        "Type \(phrase) and press return to remove these items. Anything else stops."

    public static let stopped = "Nothing was removed."

    /// Printed instead of a prompt when standard input is not a terminal.
    ///
    /// Without this, `yes | devcleaner clean` and a cron line both satisfy the gate — the
    /// answer arrives without a person ever seeing the list. There is deliberately no
    /// non-interactive way to delete: the dry run is the scriptable command.
    public static let needsATerminal =
        "devcleaner clean asks you to confirm, so it needs a terminal. "
        + "Nothing was removed. Run devcleaner clean --dry-run to see the list."

    public static func isConfirmed(_ typed: String?) -> Bool {
        guard let typed else { return false }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines) == phrase
    }
}

public enum CLIText {
    public static let usage = """
        devcleaner — inspect and clean developer caches

          devcleaner scan              list everything, with sizes and what is kept
          devcleaner protect           show why each project, device, and SDK is kept
          devcleaner clean --dry-run   print exactly what would be removed, remove nothing
          devcleaner clean             move caches to the Trash, delete devices, then report

        Only devcleaner clean removes anything, and it asks you to type \
        \(CleanConfirmation.phrase) at a
        prompt first. scan, protect and clean --dry-run remove nothing.

        Caches go to the Trash and stay restorable until you empty it — which also means
        the space is not free until you do. Simulators and emulators are the exception:
        the tools that remove them delete outright. Set moveToTrash to false in settings
        to delete everything outright instead.
        """

    /// Printed to standard error before a scan starts. A scan takes about 50 seconds on a
    /// real machine and every second of it is `du`, so the terminal must not look dead.
    public static let scanStarting =
        "Scanning. This measures every cache with du and takes about a minute."

    public static func progress(_ progress: ScanProgress) -> String {
        "  [\(progress.completed)/\(progress.total)] \(progress.currentTitle)"
    }

    public static func progress(_ progress: ExecutionProgress) -> String {
        "  [\(progress.completed)/\(progress.total)] \(progress.currentName)"
    }
}

// MARK: - splitting a selection into what can be got back and what cannot

/// A selection divided by whether it can be undone.
///
/// The division is not `Settings.moveToTrash` alone. `simctl delete`, `simctl runtime
/// delete` and `avdmanager delete avd` have no Trash, so every row whose
/// `DeletionMethod.path` is nil is permanent whatever that setting says — 17.8 GB of the
/// 58.0 GB a default clean removes on a real dev machine. Showing one list would tell the user
/// that all of it is restorable.
public struct RemovalSplit: Sendable, Equatable {
    public let toTrash: [CleanupItem]
    public let permanent: [CleanupItem]
    public let trashBytes: Int64
    public let permanentBytes: Int64

    /// Both totals use `ScanResult.totalBytes`, so each deletion target counts once here
    /// exactly as it counts once in the headline.
    public init(items: [CleanupItem], moveToTrash: Bool) {
        // `method.path != nil` is exactly the path cases; the three device cases are nil.
        let trashable = moveToTrash ? items.filter { $0.method.path != nil } : []
        let rest = moveToTrash ? items.filter { $0.method.path == nil } : items
        toTrash = trashable
        permanent = rest
        trashBytes = ScanResult.totalBytes(of: trashable)
        permanentBytes = ScanResult.totalBytes(of: rest)
    }
}

// MARK: - the report

/// Builds every block of text the tool prints. Nothing here reads the clock, the disk or
/// the environment: the time comes in as `now` and the home directory as `home`, so a test
/// gets the same string on any machine.
public struct ReportText: Sendable {
    public let home: String

    public init(home: String) { self.home = home }

    // MARK: paths

    /// `/Users/x/dev/app` -> `~/dev/app`.
    ///
    /// The separator is part of the prefix, per the standing rule: a bare `hasPrefix`
    /// would abbreviate `/Users/xavier` against a home of `/Users/x`.
    public func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~/" + path.dropFirst(home.count + 1)
    }

    // MARK: rows

    public static let permanentNote = "removed permanently, never to the Trash"
    public static let sharedNote =
        "these bytes may be shared with files that are staying, so removing it may free less"
    public static let untickedNote = "offered but not ticked — a default clean leaves it alone"

    /// The character in the box at the start of a row.
    ///
    /// Read from `selectedByDefault`, **never** from `isDeletable`. They stopped being the
    /// same value when `startsUnticked` arrived: the two Android NDK rows are deletable and
    /// deliberately unticked, 5.6 GB that only comes back over the network. A listing that
    /// marks them `x` tells the user a default clean will take them, and it will not.
    public static func mark(for item: CleanupItem) -> String {
        guard item.isDeletable else { return "-" }
        guard item.selectedByDefault else { return " " }
        return item.risk == .elevated ? "!" : "x"
    }

    /// The two lines that make up one row of the listing.
    ///
    /// Two lines because one is not enough to tell two rows apart. A representative scan produces
    /// two rows both named `shared-project-name`, both 13.6 MB, both detailed "changed in the
    /// last 14 days", from `~/dev/workspace-one` and `~/dev/workspace-two/client-app`.
    /// The only thing that separates them is the deletion target, so the target is printed.
    public func rowLines(_ item: CleanupItem) -> [String] {
        let suffix = item.protection.map { "  [kept: \($0.description)]" }
            ?? (item.detail.map { "  (\($0))" } ?? "")
        let first = "  [\(Self.mark(for: item))] "
            + ByteText.short(item.sizeBytes).leftPadded(to: 9)
            + "  \(item.name)\(suffix)"
        // Indented to sit under the name: 2 + "[x] " + a 9-wide size column + 2.
        return [first, String(repeating: " ", count: 17) + targetLine(item)]
    }

    /// What the row would actually remove, and anything the size does not admit on its own.
    public func targetLine(_ item: CleanupItem) -> String {
        var parts: [String] = [target(of: item.method)]
        // Only where it can actually happen. A protected device is never removed, so
        // saying "removed permanently" beside a row marked kept reads as a threat the
        // listing then contradicts two columns to the left.
        if item.isDeletable, item.method.path == nil { parts.append(Self.permanentNote) }
        if item.sizeMayBeShared { parts.append(Self.sharedNote) }
        if item.startsUnticked { parts.append(Self.untickedNote) }
        return parts.joined(separator: " · ")
    }

    /// Exhaustive with no `default`, so a new `DeletionMethod` case stops the build here
    /// rather than being printed as an empty string.
    public func target(of method: DeletionMethod) -> String {
        switch method {
        case .removePath(let path):                    return abbreviate(path)
        case .deleteSimulator(let udid):               return "simulator \(udid)"
        case .deleteSimulatorRuntime(let identifier):  return "runtime \(identifier)"
        case .deleteAVD(let name):                     return "emulator \(name)"
        }
    }

    // MARK: totals

    /// **The headline, always an upper bound.**
    ///
    /// It begins "up to" and it never says "freed". `reclaimableBytes` is the most a
    /// default clean can remove, not a promise: `possiblySharedBytes` of it — the pnpm
    /// store and the bun cache, 1.8 GB on a real dev machine — may be blocks shared with project
    /// `node_modules` that are staying, and those come back only when the last reference
    /// goes. When that part is not zero the number is printed as a range, because a single
    /// figure there would be wrong at one end or the other.
    public static func headline(_ result: ScanResult) -> String {
        let top = ByteText.short(result.reclaimableBytes)
        let shared = result.possiblySharedBytes
        guard shared > 0 else { return "up to \(top)" }
        let low = ByteText.short(result.reclaimableBytes - shared)
        return "up to \(top) — really \(low) to \(top), because \(ByteText.short(shared)) "
            + "of it may be shared with files that are staying"
    }

    /// A byte count that keeps its sign. `ByteText.short` clamps a negative to zero, which
    /// is right for a size and wrong for the free-space change: a run that left the disk
    /// 50 MB busier would print "0 KB" and look like it did nothing.
    public static func signed(_ bytes: Int64) -> String {
        guard bytes < 0 else { return ByteText.short(bytes) }
        return "-" + ByteText.short(Int64(clamping: bytes.magnitude))
    }

    // MARK: scan

    public func scan(_ result: ScanResult, now: Date, moveToTrash: Bool) -> String {
        var lines: [String] = []

        for group in GroupID.allCases {
            let items = result.items(in: group)
            guard !items.isEmpty else { continue }
            lines.append("")
            lines.append("\(group.title)  —  \(ByteText.short(result.reclaimableBytes(in: group)))"
                + " ticked, \(items.count) row\(items.count == 1 ? "" : "s")")
            // Biggest first, and ties broken by id so the listing is the same every run.
            for item in items.sorted(by: Self.byDescendingSize) {
                lines.append(contentsOf: rowLines(item))
            }
        }

        if !result.skippedScannerIDs.isEmpty {
            lines.append("")
            lines.append("Skipped by settings: \(result.skippedScannerIDs.joined(separator: ", "))")
        }
        if !result.ignoredProjectRoots.isEmpty {
            lines.append("")
            lines.append("Project roots ignored, too wide to walk: "
                + result.ignoredProjectRoots.map(abbreviate).joined(separator: ", "))
        }

        let split = RemovalSplit(items: result.defaultSelection, moveToTrash: moveToTrash)
        lines.append("")
        lines.append("Ticked by default:    \(Self.headline(result))")
        lines.append("  to the Trash:       \(ByteText.short(split.trashBytes)) "
            + "across \(split.toTrash.count) rows — restorable until you empty it")
        lines.append("  permanently:        \(ByteText.short(split.permanentBytes)) "
            + "across \(split.permanent.count) rows — no Trash, no undo")
        lines.append("Offered, not ticked:  \(ByteText.short(result.untickedDeletableBytes)) "
            + "— devcleaner clean leaves these alone")
        lines.append("Free space now:       \(ByteText.short(result.availableBytes))")
        lines.append("Scanned:              \(AgeText.since(result.generatedAt, now: now))")
        lines.append("")
        lines.append("Legend: [x] will be removed   [!] will be removed (higher risk)")
        lines.append("        [ ] offered, not ticked   [-] kept, cannot be removed")
        lines.append("")
        lines.append("Nothing has been removed. "
            + "Run devcleaner clean --dry-run to see the exact list.")
        return lines.joined(separator: "\n")
    }

    static func byDescendingSize(_ left: CleanupItem, _ right: CleanupItem) -> Bool {
        left.sizeBytes == right.sizeBytes ? left.id < right.id : left.sizeBytes > right.sizeBytes
    }

    // MARK: protect

    /// Why each project, device and SDK is being kept.
    ///
    /// Devices come from `protectedSimulatorUDIDs` and `protectedAVDNames`, not from
    /// `keptSimulatorUDID` and `keptAVDName`. The singular fields name one device for
    /// labelling; the maps hold **every** device that must survive, which on a real dev machine
    /// is more than one. Printing only the winner would tell the user that a simulator they
    /// used yesterday is unprotected when it is not.
    public func protection(_ set: ProtectionSet) -> String {
        var lines: [String] = []

        lines.append("Protected projects (\(set.projects.count)) — nothing of theirs is removed:")
        if set.projects.isEmpty {
            lines.append("  none")
        }
        // Keyed by full path, printed by full path. Two representative projects share the
        // name `shared-project-name`; only the path tells them apart.
        for (path, reason) in set.projects.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(abbreviate(path)) — \(reason.description)")
        }

        lines.append("")
        lines.append("Protected simulators (\(set.protectedSimulatorUDIDs.count)):")
        lines.append(contentsOf: deviceLines(set.protectedSimulatorUDIDs))
        lines.append("  labelled as the one kept: \(set.keptSimulatorUDID ?? "none")")

        lines.append("")
        lines.append("Protected emulators (\(set.protectedAVDNames.count)):")
        lines.append(contentsOf: deviceLines(set.protectedAVDNames))
        lines.append("  labelled as the one kept: \(set.keptAVDName ?? "none")")

        lines.append("")
        lines.append("Protected simulator runtimes (\(set.runtimeIdentifiers.count)):")
        lines.append(contentsOf: deviceLines(set.runtimeIdentifiers))

        lines.append("")
        lines.append("Flutter SDKs in use (\(set.flutterVersions.count)):")
        lines.append(contentsOf: deviceLines(set.flutterVersions))

        lines.append("")
        lines.append("Gradle distributions in use (\(set.gradleDistributions.count)):")
        lines.append(contentsOf: deviceLines(set.gradleDistributions))
        return lines.joined(separator: "\n")
    }

    private func deviceLines(_ entries: [String: ProtectionReason]) -> [String] {
        guard !entries.isEmpty else { return ["  none"] }
        return entries.sorted { $0.key < $1.key }.map { "  \($0.key) — \($0.value.description)" }
    }

    // MARK: the plan, shown before a dry run and before the real thing

    /// The exact list, split by whether it can be got back, with the warnings above it.
    ///
    /// `warnings` comes from `CleanerService.warnings(for:)`, so the sentence about devices
    /// being removed permanently is printed **before** anything happens rather than
    /// explained afterwards. Afterwards is too late: there is no Trash to look in.
    public func plan(
        items: [CleanupItem], warnings: [String], moveToTrash: Bool
    ) -> String {
        let split = RemovalSplit(items: items, moveToTrash: moveToTrash)
        var lines: [String] = []
        lines.append("\(items.count) rows selected, "
            + "up to \(ByteText.short(ScanResult.totalBytes(of: items))).")

        lines.append("")
        lines.append("To the Trash, restorable until you empty it — "
            + "\(split.toTrash.count) rows, \(ByteText.short(split.trashBytes)):")
        lines.append(contentsOf: planLines(split.toTrash))

        lines.append("")
        lines.append("Removed permanently, no Trash and no undo — "
            + "\(split.permanent.count) rows, \(ByteText.short(split.permanentBytes)):")
        lines.append(contentsOf: planLines(split.permanent))

        for warning in warnings {
            lines.append("")
            lines.append("!  \(warning)")
        }
        return lines.joined(separator: "\n")
    }

    private func planLines(_ items: [CleanupItem]) -> [String] {
        guard !items.isEmpty else { return ["  none"] }
        return items.sorted(by: Self.byDescendingSize).map(planLine)
    }

    /// One line of the plan: size, the name the user knows it by, and the exact thing that
    /// will be removed.
    ///
    /// The name is here and not only in the listing because the permanent side of the plan
    /// is the side worth reading twice, and a bare UDID —
    /// `00000000-0000-4000-8000-000000000001` — does not tell anybody which simulator is
    /// about to be destroyed. The permanence sentence is left off: the section heading
    /// above these lines already says it once, for all of them.
    private func planLine(_ item: CleanupItem) -> String {
        var line = "  " + ByteText.short(item.sizeBytes).leftPadded(to: 9)
            + "  \(item.name) — " + target(of: item.method)
        if item.sizeMayBeShared { line += " · " + Self.sharedNote }
        return line
    }

    // MARK: the run

    /// What a finished run did, as **three separate numbers**.
    ///
    /// Trashed bytes, permanently deleted bytes and the measured free-space change are
    /// three different quantities and are never added together. A real run on a real dev machine
    /// trashed 6.15 GB and changed free space by 60 MB, because the Trash still held the
    /// rest. One merged "freed" figure would send the user to empty the Trash expecting
    /// nothing to happen.
    public func run(_ record: RunRecord) -> String {
        var lines: [String] = []

        if !record.entries.filter(\.isRestorable).isEmpty {
            lines.append("Moved to the Trash — you can drag these back:")
            for entry in record.entries where entry.isRestorable {
                lines.append("  " + ByteText.short(entry.sizeBytes).leftPadded(to: 9)
                    + "  " + abbreviate(entry.trashedTo ?? entry.target))
            }
            lines.append("")
        }

        if !record.permanentlyDeletedEntries.isEmpty {
            lines.append("Removed permanently — these cannot be got back:")
            for entry in record.permanentlyDeletedEntries {
                lines.append("  " + ByteText.short(entry.sizeBytes).leftPadded(to: 9)
                    + "  " + abbreviate(entry.target))
            }
            lines.append("")
        }

        // Skipped first: a skipped row is usually the one the user can fix and retry, and
        // the reason names what to fix. A bare "skipped: 2" is nothing to act on.
        if !record.unfinishedReasons.isEmpty {
            lines.append("Not removed:")
            for entry in record.skippedEntries {
                lines.append("  skipped: \(entry.name) — \(entry.reason ?? "no reason given")")
            }
            for entry in record.failedEntries {
                lines.append("  failed: \(entry.name) — \(entry.reason ?? "no reason given")")
            }
            lines.append("")
        }

        for note in record.notes { lines.append("note: \(note)") }
        if !record.notes.isEmpty { lines.append("") }

        lines.append("""
            Moved to Trash:       \(ByteText.short(record.trashedBytes)) \
            (\(record.trashedCount) items)
            Permanently deleted:  \(ByteText.short(record.permanentlyDeletedBytes)) \
            (\(record.deletedCount) items — simulators and emulators cannot be trashed)
            Free space change:    \(Self.signed(record.freeSpaceChangeBytes))
            Failed: \(record.failedCount)   Skipped: \(record.skippedCount)
            """)
        lines.append("")
        lines.append("Those are three different numbers. Trashing moves bytes; it does not "
            + "release them.")

        if record.trashedBytes > 0 {
            lines.append("")
            lines.append("""
                Empty the Trash to actually free the \
                \(ByteText.short(record.trashedBytes)) it now holds. Until you do, \
                that space is still in use.
                """)
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    /// Right-aligns in a column of `width`, so a column of sizes lines up on the unit.
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
