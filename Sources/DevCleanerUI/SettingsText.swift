import Foundation
import CleanerCore

/// One switch in the scanners section.
public struct ScannerRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String

    /// Whether the switch is on, which is the opposite of what the file stores.
    ///
    /// `Settings.alwaysSkipScannerIDs` records what to **skip**; the switch offers to **look
    /// at** it. This is the reading half of that inversion, and `SettingsModel.setScannerOn`
    /// is the writing half. Both live here rather than in the view, where a lost `!` inverts
    /// all sixteen switches and no test can see it.
    public func isOn(in draft: Settings) -> Bool { !draft.isSkipped(id) }
}

/// Which of the two device pickers is being drawn.
///
/// The pair exists because everything about them differs except their shape: a different
/// label, a different scanner behind the list, a different field in `Settings`, and a
/// different sentence when there is nothing to show. Written out twice in the view, the two
/// halves drift — a picker that reads the other one's switch says "switched off" beside the
/// emulators the scan did in fact measure.
public enum DeviceKind: Sendable, Equatable, CaseIterable {
    case simulator
    case emulator

    public var label: String {
        switch self {
        case .simulator: return SettingsText.simulator
        case .emulator:  return SettingsText.emulator
        }
    }

    /// The scanner whose rows fill this picker.
    ///
    /// Asked of the scanner type itself rather than written out as a string.
    /// `Settings.alwaysSkipScannerIDs` and `ScanResult.skippedScannerIDs` both hold these
    /// identifiers, so a copy here would go on naming the old one after a rename and the
    /// note would blame a switch the scanners section no longer offers.
    public var scannerID: String {
        switch self {
        case .simulator: return SimulatorDevicesScanner().id
        case .emulator:  return AVDScanner().id
        }
    }

    /// The devices of this kind in a scan, or none when there has not been one.
    ///
    /// The `nil` case is answered here rather than with a stand-in empty `ScanResult` built
    /// in the view: an invented result is a view deciding what "no scan yet" looks like, and
    /// `deviceNote` below has to tell that case apart from a scan that really found none.
    public func choices(in result: ScanResult?) -> [DeviceChoice] {
        guard let result else { return [] }
        switch self {
        case .simulator: return PickerChoices.simulators(in: result)
        case .emulator:  return PickerChoices.emulators(in: result)
        }
    }
}

/// Every word the settings window says, and the list of scanners it offers.
public enum SettingsText {
    // Spec §8.4, in the order the window lays them out.
    public static let projectRootsTitle = "Where your code lives"
    public static let projectRootsHelp =
        "Projects under these folders are checked for recent work, and their build "
        + "folders are what the Projects group offers."
    public static let newRootPrompt = "~/dev"
    public static let addRoot = "Add"
    public static let removeRoot = "Remove"

    public static let keepingTitle = "Keeping things"
    public static let activeThreshold = "A project is active if it changed in the last"
    public static let deviceRecentUse = "Keep every simulator and emulator used in the last"
    public static let archiveAge = "Offer Xcode archives older than"
    public static let days = "days"
    public static let hours = "hours"

    public static let pinnedProjectsTitle = "Pinned projects"
    public static let pinnedProjectsHelp =
        "A pinned project is kept whatever its dates say. Pinning always wins."
    public static let noProjectsYet =
        "No projects found yet. Rescan from the popover, or add the folder your code is in above."

    public static let keptDevicesTitle = "Kept devices"
    public static let automaticDevice = "Most recently used"
    public static let simulator = "Simulator"
    public static let emulator = "Emulator"
    public static let noDevicesYet =
        "No devices found yet. Rescan from the popover to list them."

    public static let scannersTitle = "What to look at"
    public static let scannersHelp =
        "A scanner switched off here is not measured and is left out of the total."

    public static let appTitle = "The app"
    public static let backgroundInterval = "Scan again every"
    public static let menuBarShowsAmount = "Show the amount in the menu bar"
    public static let moveToTrash = "Move caches to the Trash"
    /// Names both halves of the truth, because the switch changes only one of them.
    public static let moveToTrashHelp =
        "On, caches go to the Trash and you can drag them back — but the space is not "
        + "free until you empty it. Off, they are removed outright and cannot be "
        + "recovered. Simulators, runtimes and emulators are removed permanently either "
        + "way; the tools that remove them have no Trash."

    public static let save = "Save"

    // MARK: - the device pickers

    /// Past tense on purpose. `DeviceChoice.isKept` is a snapshot of the last scan, not live
    /// truth: the protection that produced it is recomputed on every scan from dates that
    /// have moved since. "kept" alone reads as a promise about right now, and the promise
    /// this window can actually make is a pin.
    public static let keptByTheLastScan = "kept by the last scan"

    /// One row of a device picker: which device, what it costs, and whether the last scan
    /// already kept it.
    ///
    /// The size is not decoration. Two simulators on a real dev machine are both called
    /// `iPhone 17`, and with the name alone the user pins whichever one the list happens to
    /// put first.
    public static func deviceLabel(_ choice: DeviceChoice) -> String {
        let head = "\(choice.name) — \(choice.sizeText)"
        return choice.isKept ? "\(head) · \(keptByTheLastScan)" : head
    }

    /// Shown when this picker is empty because the last scan never looked.
    ///
    /// A separate sentence from `noDevicesYet`, which asks for a rescan: the rescan would
    /// skip the same scanner and leave the picker exactly as empty. The switch is what has
    /// to change, so the sentence names it and where it is.
    public static func deviceScannerIsOff(_ kind: DeviceKind) -> String {
        "\(kind.label) scanning is switched off under \(scannersTitle), so the last scan "
        + "listed none. Switch it on and rescan to choose one."
    }

    /// Shown when the stored pin is not one of the rows offered.
    ///
    /// A `Picker` whose selection matches no row draws blank, which reads as "nothing is
    /// pinned" — and the pinned simulator is the one thing standing between a device and
    /// `simctl delete`, which has no Trash and no undo. Naming the stored value says the pin
    /// is still there and still honoured, so nobody re-pins over it or gives up on it.
    public static func pinnedDeviceIsMissing(_ id: String) -> String {
        "\(id) is still pinned and still kept. The last scan did not list it, so it cannot "
        + "be shown above."
    }

    /// What the kept-devices section says beside a picker, or `nil` when the picker speaks
    /// for itself.
    ///
    /// Two facts, and both are needed at once: an empty picker has to say *why* it is empty,
    /// and a pin that is not in the list has to say it survived. A sentence for only the
    /// first leaves a window that looks like it lost a setting it did not lose.
    public static func deviceNote(
        _ kind: DeviceKind, choices: [DeviceChoice], result: ScanResult?, pinned: String?
    ) -> String? {
        var sentences: [String] = []
        if choices.isEmpty {
            // `ScanResult.skippedScannerIDs` rather than the draft's own switches: this
            // answers why *the list on screen* is empty, and the list came from that scan.
            // A switch the user has just flipped and not yet saved says nothing about it.
            let wasSkipped = result?.skippedScannerIDs.contains(kind.scannerID) ?? false
            sentences.append(wasSkipped ? deviceScannerIsOff(kind) : noDevicesYet)
        }
        if let pinned, !choices.contains(where: { $0.id == pinned }) {
            sentences.append(pinnedDeviceIsMissing(pinned))
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    // MARK: - the project pin list

    /// Shown when the list is empty because every root the draft holds was refused as too
    /// wide to be a project root.
    ///
    /// `noProjectsYet` is wrong here twice over: it asks for a rescan, and the rescan refuses
    /// the same roots and lists nothing again; and it is printed directly under the root that
    /// caused it, offering to add a folder when the fix is to remove one.
    public static let everyProjectRootWasRefused =
        "Every folder above was refused as too wide to be a project root. Remove them and "
        + "name the folder your code is in, such as ~/dev, then rescan."

    /// What the pinned-projects section says instead of a list, or `nil` when it has one.
    ///
    /// The same shape as `deviceNote`: an empty list has to say *why* it is empty, because
    /// the two reasons need opposite advice.
    public static func projectNote(
        choices: [ProjectChoice], draft: Settings, result: ScanResult?
    ) -> String? {
        guard choices.isEmpty else { return nil }
        // Nothing left to walk, but roots are listed above: every one of them was refused.
        // An empty `projectRoots` is the other empty list entirely — there is nothing to
        // remove, and "add the folder your code is in" is exactly right.
        if !draft.projectRoots.isEmpty,
           PickerChoices.usableRoots(draft: draft, result: result).isEmpty {
            return everyProjectRootWasRefused
        }
        return noProjectsYet
    }

    // MARK: - the scanners section

    /// One row per scanner in the registry, in the registry's order.
    ///
    /// Built from `CleanerService.allScanners()` rather than a list written here, because
    /// `Settings.alwaysSkipScannerIDs` stores those identifiers: a hand-written list that
    /// missed one — `android.ndk` was added to the package after the engine plan was
    /// written — would leave a scanner nobody can switch off, and one that misspelled an
    /// identifier would write a setting that does nothing.
    public static func scannerRows() -> [ScannerRow] {
        CleanerService.allScanners().map { ScannerRow(id: $0.id, title: $0.title) }
    }
}
