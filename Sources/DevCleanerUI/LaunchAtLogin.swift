import Foundation
import ServiceManagement

/// The login item, behind a protocol so tests never register anything with the system.
public protocol LoginItemControlling: Sendable {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

/// The real one. `SMAppService.mainApp` is the app's own bundle, which is why
/// `Scripts/make-app.sh` exists at all: run from a bare SwiftPM binary there is no bundle
/// identifier to register and `register()` throws.
public struct SystemLoginItem: LoginItemControlling {
    public init() {}

    public func isEnabled() -> Bool { SMAppService.mainApp.status == .enabled }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

public enum LaunchAtLoginText {
    public static let label = "Launch at login"
    public static let notBundled =
        "Launch at login needs DevCleaner.app. Run Scripts/make-app.sh, move the app to "
        + "/Applications, and open it from there."

    /// Shown when the system took the change and still reports the login item as off.
    ///
    /// That is approval waiting for the user: `register()` returns and the status stays at
    /// `.requiresApproval` until they answer. The switch is drawn from the system, so it
    /// springs straight back to off on its own — and without this sentence nothing on screen
    /// says why, which reads as the setting silently refusing to stick.
    public static let pending =
        "Launch at login is waiting for your approval. Open System Settings ▸ General ▸ "
        + "Login Items and switch DevCleaner on there. The switch above stays off until you do."

    public static func failure(_ error: any Error) -> String {
        "Launch at login could not be changed: \(error.localizedDescription). "
        + notBundled
    }
}

/// Couples the switch to the system, and refuses to record a setting the system rejected.
///
/// The order matters: the system is asked **first**, and `Settings.launchAtLogin` is only
/// written if it agreed. Writing the setting first and registering afterwards leaves a
/// settings file that says the app starts at login when it does not, and nothing tells the
/// user until the next restart.
/// Not `Equatable`. The only honest comparison would have to include `loginItem`, which is
/// an existential with no identity to compare, and the brief's version — comparing `message`
/// alone — calls two models equal while one reports the login item on and the other off.
/// SwiftUI view diffing is exactly the caller that would act on that answer. Nothing needs
/// the conformance, so there is none.
public struct LaunchAtLoginModel: Sendable {
    private let loginItem: any LoginItemControlling
    public private(set) var message: String?

    public init(loginItem: any LoginItemControlling = SystemLoginItem()) {
        self.loginItem = loginItem
        self.message = nil
    }

    /// Read from the system, not from the settings file. A user who removed the login item
    /// in System Settings never told this app about it.
    public var isOn: Bool { loginItem.isEnabled() }

    /// Records **what was asked for**, not what the system reports a moment later.
    ///
    /// `register()` can succeed while `status` is still short of `.enabled` — approval is
    /// pending until the user answers System Settings. Writing `isEnabled()` into the draft
    /// here would store "off" for a login item that is on its way to being registered, so
    /// Save would write the opposite of what the user asked for.
    ///
    /// It does **not** stop the switch springing back: `isOn` is the system's answer, so an
    /// unapproved registration draws as off whatever the draft says. That is why the same
    /// case produces a message. Silence there is the switch appearing to refuse to stick.
    public mutating func set(_ on: Bool, in settings: inout SettingsModel) {
        do {
            try loginItem.setEnabled(on)
            settings.setLaunchAtLogin(on)
            message = (on && !loginItem.isEnabled()) ? LaunchAtLoginText.pending : nil
        } catch {
            message = LaunchAtLoginText.failure(error)
        }
    }
}
