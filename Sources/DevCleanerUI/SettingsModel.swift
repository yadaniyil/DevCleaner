import Foundation
import CleanerCore

/// A simulator or emulator the user can pin, with what it costs and whether it is already
/// being kept.
public struct DeviceChoice: Sendable, Equatable, Identifiable {
    /// The UDID for a simulator, the AVD name for an emulator: exactly what
    /// `Settings.pinnedSimulatorUDID` and `Settings.pinnedAVDName` store.
    public let id: String
    public let name: String
    public let sizeText: String
    /// Already protected by the automatic rules. Shown so pinning the device the tool
    /// would keep anyway is visibly a no-op rather than a mystery.
    public let isKept: Bool
}

public struct ProjectChoice: Sendable, Equatable, Identifiable {
    /// The project's absolute directory, which is what `Settings.pinnedProjectPaths`
    /// stores.
    public let id: String
    public let name: String
    /// `~/dev/sample-project`. Two representative projects share the name `shared-project-name`, so
    /// the path is the label, not the decoration.
    public let displayPath: String
}

public enum PickerChoices {
    /// Every simulator the scan met, protected ones included.
    ///
    /// `SimulatorDevicesScanner` emits a row for every device — that is what puts the
    /// the deck's own "left alone because they are in use" lines — so the scan result is the
    /// complete list, with
    /// the name and the measured size already in it. There is no "list every device" call
    /// on `CleanerService` to ask instead.
    public static func simulators(in result: ScanResult) -> [DeviceChoice] {
        result.items.compactMap { item in
            guard case .deleteSimulator(let udid) = item.method else { return nil }
            return DeviceChoice(
                id: udid, name: item.name, sizeText: ByteText.short(item.sizeBytes),
                isKept: !item.isDeletable)
        }
    }

    public static func emulators(in result: ScanResult) -> [DeviceChoice] {
        result.items.compactMap { item in
            guard case .deleteAVD(let name) = item.method else { return nil }
            return DeviceChoice(
                id: name, name: item.name, sizeText: ByteText.short(item.sizeBytes),
                isKept: !item.isDeletable)
        }
    }

    /// The roots the settings window's pin list may walk: the draft's own, less the ones the
    /// last scan refused.
    ///
    /// Every string is passed through **exactly as stored**, because
    /// `ScanResult.ignoredProjectRoots` holds the same raw strings and the two are matched as
    /// text. A value changed on the way past — abbreviated for display, expanded, resolved —
    /// stops matching, and a root the engine refused as too wide is then walked anyway. For
    /// `~` that means the whole home directory, four levels deep, with every "project" found
    /// there walked again for its newest file: minutes of a frozen settings window, and the
    /// user's Documents folder arriving as checkboxes.
    ///
    /// That a stored root may not be absolute is not hypothetical. `SettingsStore.load`
    /// expands a leading `~/`, but it does not *validate* a hand-edited file, and the shapes
    /// `TildePath` deliberately leaves alone — a bare `~`, `~someone/dev`, a plain relative
    /// `dev` — all survive the trip and arrive here exactly as typed.
    ///
    /// Separate from `projects(draft:result:home:)` so this rule can be read and tested on its
    /// own: that one walks the disk, and a test of it cannot tell "the root was filtered out"
    /// apart from "the root held nothing".
    public static func usableRoots(draft: Settings, result: ScanResult?) -> [String] {
        // No scan yet is no refusal to honour, not "refuse everything".
        let refused = result?.ignoredProjectRoots ?? []
        return draft.projectRoots.filter { !refused.contains($0) }
    }

    /// The project pin list for the settings window, from the draft the user is editing and
    /// the scan on screen.
    ///
    /// `ignoredRoots` is empty on purpose: `usableRoots` has already applied that rule, and
    /// applying it twice would mean a broken `usableRoots` still produced the right list, so
    /// nothing downstream could ever notice.
    public static func projects(
        draft: Settings, result: ScanResult?, home: String
    ) -> [ProjectChoice] {
        projects(roots: usableRoots(draft: draft, result: result), ignoredRoots: [], home: home)
    }

    /// Every project under the roots, for the pin list.
    ///
    /// `ignoredRoots` is `ScanResult.ignoredProjectRoots` — the roots the engine itself
    /// refused as too wide. Filtering by the engine's answer rather than re-implementing
    /// `SettingsStore.isTooWideForAProjectRoot`, which is internal, keeps one rule in one
    /// place: walking `~` four levels deep and then inspecting every "project" found there
    /// takes minutes and lists the user's Documents folder.
    ///
    /// De-duplicated by path, because `ProjectDiscovery.discover(roots:)` appends per root
    /// and never de-duplicates: a user whose roots hold both `~/dev` and `~/dev/app` would
    /// otherwise see that project twice with one checkbox each.
    public static func projects(
        roots: [String], ignoredRoots: [String],
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> [ProjectChoice] {
        let usable = roots.filter { !ignoredRoots.contains($0) }
        let reporter = ReportText(home: home)
        var seen: Set<String> = []
        return ProjectDiscovery(fileManager: fileManager)
            .discover(roots: usable)
            .filter { seen.insert($0.path).inserted }
            // By path, so the order never depends on which root was walked first.
            .sorted { $0.path < $1.path }
            .map {
                ProjectChoice(
                    id: $0.path, name: $0.name, displayPath: reporter.abbreviate($0.path))
            }
    }
}

/// The settings window's working copy, per spec §8.4.
///
/// A draft rather than live edits, so a value the store refuses is still on screen with
/// the reason beside it. The engine's refusal is the authority: `SettingsStore.save`
/// throws `SettingsError.projectRootTooWide` and writes nothing, and that error's own
/// sentence is what the user reads. Writing a second, friendlier sentence here would mean
/// the check and the message could drift apart.
public struct SettingsModel: Sendable, Equatable {
    public private(set) var draft: Settings
    /// What went wrong with the last thing the user did. `nil` when nothing did.
    public private(set) var message: String?
    /// Whether there is anything to save.
    public private(set) var isDirty: Bool
    /// The home directory a typed `~/…` is resolved against. Injected rather than read from
    /// the environment so a test gets the same answer on any machine.
    private let home: String

    public init(settings: Settings, home: String) {
        self.draft = settings
        self.message = nil
        self.isDirty = false
        self.home = home
    }

    // MARK: project roots

    /// Stores an absolute path, expanding a leading `~/` first.
    ///
    /// `TildePath.expanded` is the engine's own expansion, the same one `SettingsStore.load`
    /// applies to a hand-edited file and the same one `isTooWideForAProjectRoot` measures
    /// against, so the value on screen, the value refused and the value walked cannot
    /// disagree about which directory a root names.
    ///
    /// Expanding **here** as well as on load is not belt and braces. This draft is what the
    /// window shows and what `PickerChoices.usableRoots` and `projects(draft:result:home:)`
    /// walk, and none of that waits for a save-and-reload — so a root typed as `~/work` has
    /// to become a real directory before it is added, or the pin list under it is empty
    /// until the app is restarted.
    ///
    /// A bare `~` is left as typed, which `TildePath` does for everyone: it is refused by
    /// `SettingsStore.save` either way, and leaving it alone means the sentence the user
    /// reads quotes what they actually typed rather than a path they never wrote.
    public mutating func addProjectRoot(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "Type the folder your code is in, such as ~/dev."
            return
        }
        let expanded = TildePath.expanded(trimmed, home: home)
        guard !draft.projectRoots.contains(expanded) else {
            message = "\(expanded) is already a project root."
            return
        }
        draft.projectRoots.append(expanded)
        accepted()
    }

    public mutating func removeProjectRoot(_ path: String) {
        draft.projectRoots.removeAll { $0 == path }
        accepted()
    }

    // MARK: numbers

    /// Spec §8.4: active threshold in days, default 14. At least one day — a threshold of
    /// zero protects nothing, and every project's build output is then offered.
    public mutating func setActiveThresholdDays(_ text: String) {
        setWholeNumber(text, least: 1, name: "Active threshold") { $0.activeThresholdDays = $1 }
    }

    /// Zero is meaningful here: "protect only the simulator I am running right now".
    public mutating func setDeviceRecentUseDays(_ text: String) {
        setWholeNumber(text, least: 0, name: "Device recent use") { $0.deviceRecentUseDays = $1 }
    }

    /// Zero is meaningful here too: "offer every archive".
    public mutating func setArchiveAgeDays(_ text: String) {
        setWholeNumber(text, least: 0, name: "Archive age") { $0.archiveAgeDays = $1 }
    }

    /// At least one hour. `ScanScheduler` clamps this as well, because a hand-edited file
    /// never passes through here.
    public mutating func setBackgroundScanIntervalHours(_ text: String) {
        setWholeNumber(text, least: 1, name: "Background scan interval") {
            $0.backgroundScanIntervalHours = $1
        }
    }

    /// Refuses rather than coercing. `Int("fourteen")` is nil and `Int("14abc")` is nil
    /// too; silently substituting a default would change a setting the user believes they
    /// typed, and one of these settings decides which device survives a permanent delete.
    ///
    /// The floor is checked as well as the format. A negative day count is not a smaller
    /// number, it is a cutoff in the future: `deviceRecentUseDays` of -1 protects no device
    /// at all, so a simulator booted this morning is offered for a delete with no Trash
    /// behind it.
    private mutating func setWholeNumber(
        _ text: String, least: Int, name: String, _ apply: (inout Settings, Int) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else {
            message = "\(name) must be a whole number, not \"\(trimmed)\"."
            return
        }
        guard value >= least else {
            message = "\(name) must be at least \(least)."
            return
        }
        apply(&draft, value)
        accepted()
    }

    // MARK: switches and pins

    /// Known identifiers in `CleanerService.scannerIDs` order, then anything the registry
    /// does not recognise.
    ///
    /// The registry is the authority on the order, and this file is read by a person: a
    /// stable order means a diff of `settings.json` shows what changed.
    ///
    /// The unrecognised ones are **kept**, not filtered out. An identifier this build does
    /// not know is harmless — `Settings.isSkipped` is a plain `contains`, so it switches
    /// nothing on and nothing off. Dropping it is the harmful direction: after a scanner is
    /// renamed, or on a downgrade to a build that predates one, flipping any single switch
    /// would quietly rewrite the file without every skip it did not recognise, and going
    /// back to the newer build would find those scanners switched on again with nothing in
    /// the file to say why. That is the same shape as the phase-1 settings bug — a user's
    /// stored choice discarded by an upgrade, silently.
    /// Unrecognised entries keep the order the file had them in. Nothing here is written out
    /// of a `Set`: a set's iteration order is seeded per process, so the same switches would
    /// produce a different file on the next launch and every diff would be noise.
    public mutating func setSkipped(_ scannerID: String, _ skipped: Bool) {
        var ids = draft.alwaysSkipScannerIDs.filter { $0 != scannerID }
        if skipped { ids.append(scannerID) }
        let known = Set(CleanerService.scannerIDs)
        var seen: Set<String> = []
        draft.alwaysSkipScannerIDs = CleanerService.scannerIDs.filter(ids.contains)
            + ids.filter { !known.contains($0) && seen.insert($0).inserted }
        accepted()
    }

    /// The same switch the other way round, in the words the settings window uses.
    ///
    /// The storage means "always skip" and the switch means "look at this", so something has
    /// to invert. That inversion used to sit in the view — `set: { setSkipped(id, !$0) }` —
    /// where no test could reach it, because a test target cannot import an executable. Drop
    /// or misplace the `!` and every switch inverts together: the user turns a scanner
    /// **on**, the identifier goes into `alwaysSkipScannerIDs`, and that whole group leaves
    /// the scan and the total with nothing on screen to say why. Paired with
    /// `ScannerRow.isOn(in:)`, which is the reading half.
    public mutating func setScannerOn(_ scannerID: String, _ on: Bool) {
        setSkipped(scannerID, !on)
    }

    public mutating func setPinnedSimulator(_ udid: String?) {
        draft.pinnedSimulatorUDID = udid
        accepted()
    }

    public mutating func setPinnedAVD(_ name: String?) {
        draft.pinnedAVDName = name
        accepted()
    }

    /// Sorted by path, for the same reason the skipped identifiers keep registry order: a
    /// set written out in hash order makes a diff of `settings.json` unreadable, and these
    /// are the entries worth reading.
    public mutating func setPinned(_ projectPath: String, _ pinned: Bool) {
        var paths = Set(draft.pinnedProjectPaths)
        if pinned { paths.insert(projectPath) } else { paths.remove(projectPath) }
        draft.pinnedProjectPaths = paths.sorted()
        accepted()
    }

    public mutating func setMoveToTrash(_ on: Bool) {
        draft.moveToTrash = on
        accepted()
    }

    public mutating func setMenuBarShowsAmount(_ on: Bool) {
        draft.menuBarShowsAmount = on
        accepted()
    }

    public mutating func setLaunchAtLogin(_ on: Bool) {
        draft.launchAtLogin = on
        accepted()
    }

    /// What every setter does once the value is in the draft: clear the last refusal and
    /// let the Save button see the change.
    ///
    /// One function rather than the same two lines thirteen times, because both halves are
    /// easy to leave out and neither shows up on screen as itself. A missing `isDirty` is a
    /// change the user makes and cannot save; a stale `message` is a refusal standing beside
    /// the value that replaced it.
    private mutating func accepted() {
        message = nil
        isDirty = true
    }

    // MARK: saving

    /// Stores the draft, or keeps it on screen with the reason it was refused.
    ///
    /// The draft is **not** rolled back on failure. The user typed it, they can see it,
    /// and the message says what is wrong with it; discarding it would leave the window
    /// showing the old value with an error about a value that is no longer visible.
    @discardableResult
    public mutating func save(with engine: any CleanerEngine) -> Bool {
        do {
            try engine.save(draft)
            message = nil
            isDirty = false
            return true
        } catch let error as SettingsError {
            // The engine's own sentence: "refused: ~ is too wide to be a project root.
            // Name the folder your code is in, such as ~/dev."
            message = error.description
            return false
        } catch {
            message = "Settings could not be saved: \(error.localizedDescription)"
            return false
        }
    }
}
