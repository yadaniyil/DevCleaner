import SwiftUI
import DevCleanerUI
import CleanerCore

/// Spec §8.4. A draft of every setting, saved in one go.
///
/// Nothing here works out what to say. Every label, every empty-list sentence and every
/// refusal comes from `DevCleanerUI`, because a test target cannot import an executable:
/// a string decided in this file is a string no test can read.
struct SettingsWindowView: View {
    @Bindable var model: AppModel
    @State private var settings: SettingsModel
    @State private var newRoot = ""
    /// Defaults to the real `SMAppService`. Nothing here decides anything about it: the
    /// switch's state, the order the system and the draft are written in, and the sentence
    /// shown when the system refuses all live in `LaunchAtLoginModel`.
    @State private var launch = LaunchAtLoginModel()

    private let engine: any CleanerEngine = LiveCleanerEngine()

    /// `@MainActor` because `AppModel` is: reading `model.settings` and `model.home` from a
    /// nonisolated initialiser does not compile under strict concurrency. Every construction
    /// happens inside the `Settings` scene, which is on the main actor already.
    @MainActor
    init(model: AppModel) {
        self.model = model
        _settings = State(initialValue: SettingsModel(settings: model.settings, home: model.home))
    }

    var body: some View {
        Form {
            Section(SettingsText.projectRootsTitle) {
                Text(SettingsText.projectRootsHelp).font(.caption).foregroundStyle(.secondary)
                // The stored string, shown as stored. Abbreviating it for display would hand
                // `removeProjectRoot` a path it cannot match — the draft holds the raw value,
                // which a settings file written before this version may still spell `~/dev` —
                // and the Remove button would then quietly do nothing.
                ForEach(settings.draft.projectRoots, id: \.self) { root in
                    HStack {
                        Text(root)
                        Spacer()
                        Button(SettingsText.removeRoot) { settings.removeProjectRoot(root) }
                    }
                }
                HStack {
                    TextField(SettingsText.newRootPrompt, text: $newRoot)
                    Button(SettingsText.addRoot) {
                        settings.addProjectRoot(newRoot)
                        newRoot = ""
                    }
                }
            }

            Section(SettingsText.keepingTitle) {
                NumberField(
                    label: SettingsText.activeThreshold, unit: SettingsText.days,
                    text: Binding(
                        get: { String(settings.draft.activeThresholdDays) },
                        set: { settings.setActiveThresholdDays($0) }))
                NumberField(
                    label: SettingsText.deviceRecentUse, unit: SettingsText.days,
                    text: Binding(
                        get: { String(settings.draft.deviceRecentUseDays) },
                        set: { settings.setDeviceRecentUseDays($0) }))
                NumberField(
                    label: SettingsText.archiveAge, unit: SettingsText.days,
                    text: Binding(
                        get: { String(settings.draft.archiveAgeDays) },
                        set: { settings.setArchiveAgeDays($0) }))
            }

            Section(SettingsText.pinnedProjectsTitle) {
                Text(SettingsText.pinnedProjectsHelp).font(.caption).foregroundStyle(.secondary)
                let projects = PickerChoices.projects(
                    draft: settings.draft, result: model.result, home: model.home)
                // Which sentence an empty list gets is a decision, not a layout: a list
                // emptied by roots the engine refused needs the opposite advice to one that
                // simply found nothing.
                if let note = SettingsText.projectNote(
                    choices: projects, draft: settings.draft, result: model.result) {
                    Text(note).font(.caption)
                }
                ForEach(projects) { project in
                    Toggle(project.displayPath, isOn: Binding(
                        get: { settings.draft.pinnedProjectPaths.contains(project.id) },
                        set: { settings.setPinned(project.id, $0) }))
                }
            }

            Section(SettingsText.keptDevicesTitle) {
                DevicePicker(
                    kind: .simulator, result: model.result,
                    pinned: Binding(
                        get: { settings.draft.pinnedSimulatorUDID },
                        set: { settings.setPinnedSimulator($0) }))
                DevicePicker(
                    kind: .emulator, result: model.result,
                    pinned: Binding(
                        get: { settings.draft.pinnedAVDName },
                        set: { settings.setPinnedAVD($0) }))
            }

            Section(SettingsText.scannersTitle) {
                Text(SettingsText.scannersHelp).font(.caption).foregroundStyle(.secondary)
                // `isOn` and `setScannerOn`, never `isSkipped` and `setSkipped` with a `!`
                // either side. The storage means "always skip" and the switch means "look at
                // this"; that inversion belongs where a test can read it, because losing one
                // `!` here turns every scanner the user switches on into one the app skips.
                ForEach(SettingsText.scannerRows()) { scanner in
                    Toggle(scanner.title, isOn: Binding(
                        get: { scanner.isOn(in: settings.draft) },
                        set: { settings.setScannerOn(scanner.id, $0) }))
                }
            }

            Section(SettingsText.appTitle) {
                NumberField(
                    label: SettingsText.backgroundInterval, unit: SettingsText.hours,
                    text: Binding(
                        get: { String(settings.draft.backgroundScanIntervalHours) },
                        set: { settings.setBackgroundScanIntervalHours($0) }))
                // The odd one out in this window: every other control edits the draft and
                // does nothing until Save, while this one registers with the system the
                // moment it is flipped. Closing without saving therefore leaves the login
                // item registered and `launchAtLogin` in the file still false — which shows
                // nothing wrong, because the switch is drawn from the system rather than
                // from the file.
                Toggle(LaunchAtLoginText.label, isOn: Binding(
                    get: { launch.isOn },
                    set: { launch.set($0, in: &settings) }))
                if let message = launch.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                Toggle(SettingsText.menuBarShowsAmount, isOn: Binding(
                    get: { settings.draft.menuBarShowsAmount },
                    set: { settings.setMenuBarShowsAmount($0) }))
                Toggle(SettingsText.moveToTrash, isOn: Binding(
                    get: { settings.draft.moveToTrash },
                    set: { settings.setMoveToTrash($0) }))
                Text(SettingsText.moveToTrashHelp).font(.caption).foregroundStyle(.secondary)
            }

            // The engine's own refusal, word for word — `SettingsError.projectRootTooWide`
            // writes the sentence and `SettingsModel` carries it here unchanged. The value it
            // refused is still in the draft above, so the user can see it and remove it.
            if let message = settings.message {
                Text(message).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(SettingsText.save) {
                    if settings.save(with: engine) { model.apply(settings.draft) }
                }
                .disabled(!settings.isDirty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
    }
}

/// One kept-device picker, with the sentence that explains an empty one.
///
/// The selection is `String?`, tagged with `String?` on every row, so "most recently used"
/// is the absence of a pin rather than a sentinel string this file would have to invent and
/// map back. Getting that mapping wrong clears a pin, and a cleared pin is a simulator
/// `simctl delete` removes for good.
struct DevicePicker: View {
    let kind: DeviceKind
    let result: ScanResult?
    /// A `Binding` made by the owner rather than a setter closure stored here.
    /// `Binding.init(get:set:)` now takes `@isolated(any) @Sendable` closures, and a stored
    /// function value is neither: handing one over compiles with a data-race warning.
    @Binding var pinned: String?

    var body: some View {
        let choices = kind.choices(in: result)
        Picker(kind.label, selection: $pinned) {
            Text(SettingsText.automaticDevice).tag(String?.none)
            ForEach(choices) { choice in
                Text(SettingsText.deviceLabel(choice)).tag(String?.some(choice.id))
            }
        }
        if let note = SettingsText.deviceNote(
            kind, choices: choices, result: result, pinned: pinned) {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A labelled whole-number field. The text goes straight to `SettingsModel`, which
/// refuses anything that is not a whole number and says so; nothing is coerced here.
struct NumberField: View {
    let label: String
    let unit: String
    /// Bound to the model, for the reason given on `DevicePicker.pinned`.
    @Binding var text: String

    var body: some View {
        LabeledContent(label) {
            HStack {
                // Labelled with the same words as the row and then hidden, rather than left
                // empty: VoiceOver reads the field's own label, and an empty one announces
                // three identical unnamed text fields in the Keeping things section.
                TextField(label, text: $text)
                    .labelsHidden()
                    .frame(width: 60)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
