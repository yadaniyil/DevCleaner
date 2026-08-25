import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

struct LoginItemError: Error, LocalizedError {
    let errorDescription: String?
}

/// A login item that never touches the real one. No test in this target may register
/// anything with the system.
final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private let failure: (any Error)?
    private(set) var calls: [Bool] = []

    init(enabled: Bool = false, failure: (any Error)? = nil) {
        self.enabled = enabled
        self.failure = failure
    }

    func isEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ on: Bool) throws {
        lock.lock(); calls.append(on); lock.unlock()
        if let failure { throw failure }
        lock.lock(); enabled = on; lock.unlock()
    }
}

/// Registers happily and still reports itself off, which is what the system looks like
/// while approval is pending: `register()` returns and `status` is `.requiresApproval`,
/// not `.enabled`, until the user answers the prompt.
struct PendingApprovalLoginItem: LoginItemControlling {
    func isEnabled() -> Bool { false }
    func setEnabled(_ on: Bool) throws {}
}

/// Refuses the first change and accepts every one after it, which is what a user who
/// answers the System Settings prompt between two clicks looks like from here.
final class RefusesOnceLoginItem: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var refusalsLeft: Int
    private var enabled = false

    init(refusals: Int = 1) { self.refusalsLeft = refusals }

    func isEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ on: Bool) throws {
        lock.lock()
        let refuse = refusalsLeft > 0
        if refuse { refusalsLeft -= 1 } else { enabled = on }
        lock.unlock()
        if refuse { throw LoginItemError(errorDescription: "Operation not permitted") }
    }
}

/// `home:` is spelled out because `SettingsModel.init` has no default for it.
private func settingsModel() -> SettingsModel {
    SettingsModel(settings: .makeDefault(home: "/Users/test"), home: "/Users/test")
}

@Test func turningItOnRegistersAndRecordsTheSetting() {
    let item = FakeLoginItem()
    var settings = settingsModel()
    var launch = LaunchAtLoginModel(loginItem: item)

    launch.set(true, in: &settings)

    #expect(item.calls == [true])
    #expect(settings.draft.launchAtLogin)
    #expect(launch.message == nil)
}

@Test func turningItOffUnregisters() {
    let item = FakeLoginItem(enabled: true)
    var settings = settingsModel()
    var launch = LaunchAtLoginModel(loginItem: item)

    launch.set(false, in: &settings)

    #expect(item.calls == [false])
    #expect(!settings.draft.launchAtLogin)
}

/// The setting must not say "on" when the system refused. `SMAppService.register()`
/// throws when the app is not in a bundle — running the bare SwiftPM binary is exactly
/// that case — and a settings file claiming the login item exists would be a lie the user
/// only discovers at the next restart.
@Test func aRefusedRegistrationLeavesTheSettingOffAndSaysWhy() {
    let item = FakeLoginItem(failure: LoginItemError(errorDescription: "Operation not permitted"))
    var settings = settingsModel()
    var launch = LaunchAtLoginModel(loginItem: item)

    launch.set(true, in: &settings)

    #expect(!settings.draft.launchAtLogin)
    #expect(launch.message?.contains("Operation not permitted") == true)
}

/// The system is the authority on whether the login item exists — a user can remove it in
/// System Settings, and the file here would never hear about it.
@Test func theSwitchReadsItsStateFromTheSystem() {
    #expect(LaunchAtLoginModel(loginItem: FakeLoginItem(enabled: true)).isOn)
    #expect(!LaunchAtLoginModel(loginItem: FakeLoginItem(enabled: false)).isOn)
}

@Test func theNotBundledMessageNamesTheScriptThatBuildsTheApp() {
    #expect(LaunchAtLoginText.notBundled.contains("Scripts/make-app.sh"))
    #expect(LaunchAtLoginText.notBundled.contains("DevCleaner.app"))
}

/// The setting records what the user asked for, not what the system currently reports.
///
/// Approval can be pending: `register()` succeeds and the status stays short of `.enabled`
/// until the user answers System Settings. A model that wrote `isEnabled()` into the draft
/// instead of the requested value would make Save store "off" for a login item that is on
/// its way to being registered.
@Test func aRegistrationTheSystemHasNotApprovedYetStillRecordsTheSetting() {
    var settings = settingsModel()
    var launch = LaunchAtLoginModel(loginItem: PendingApprovalLoginItem())

    launch.set(true, in: &settings)

    #expect(settings.draft.launchAtLogin)
}

/// …and says so, because the switch itself cannot.
///
/// `isOn` is the system's answer, so an unapproved registration draws as off however the
/// draft reads: the user flips it on and watches it spring straight back. Without a sentence
/// beside it that is a setting silently refusing to stick, with the fix — one click in
/// System Settings — nowhere on screen.
@Test func aRegistrationWaitingForApprovalSaysWhereToApproveIt() {
    var settings = settingsModel()
    var launch = LaunchAtLoginModel(loginItem: PendingApprovalLoginItem())

    launch.set(true, in: &settings)

    let message = launch.message
    #expect(message == LaunchAtLoginText.pending)
    // The whole sentence, not two `contains` checks. Both halves are load-bearing and
    // neither is pinned by the other: the route through System Settings is what the user
    // acts on, and the last clause is what stops the switch springing back looking like a
    // setting that refuses to stick. A constant cut down to "Approval needed" satisfies
    // every `contains` above and tells the user nothing they can do.
    #expect(LaunchAtLoginText.pending
        == "Launch at login is waiting for your approval. Open System Settings ▸ General ▸ "
        + "Login Items and switch DevCleaner on there. The switch above stays off until you do.")
}

/// Switching **off** is never pending. `unregister()` takes effect at once, so the same
/// "the system still says off" check that raises the sentence above must not raise it here —
/// where "off" is exactly what was asked for.
@Test func switchingItOffIsNotTreatedAsWaitingForApproval() {
    var settings = settingsModel()
    var launch = LaunchAtLoginModel(loginItem: FakeLoginItem(enabled: true))

    launch.set(false, in: &settings)

    #expect(launch.message == nil)
}

/// The refusal must not outlive itself. Running the bare binary is the case that raises it,
/// but a user can also be refused once and approve the prompt a moment later — and a
/// sentence left standing beside a switch that now works says the opposite of the truth.
@Test func aChangeTheSystemAcceptsClearsTheEarlierRefusal() {
    var settings = settingsModel()
    var launch = LaunchAtLoginModel(loginItem: RefusesOnceLoginItem())

    launch.set(true, in: &settings)
    #expect(launch.message != nil)
    #expect(!settings.draft.launchAtLogin)

    launch.set(true, in: &settings)

    #expect(launch.message == nil)
    #expect(settings.draft.launchAtLogin)
}
