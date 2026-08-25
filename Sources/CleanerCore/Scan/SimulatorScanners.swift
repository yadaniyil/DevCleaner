import Foundation

public struct SimulatorDevicesScanner: CleanupScanner {
    public let id = "ios.simulators"
    public let group = GroupID.xcodeAndIOS
    public let title = "iOS simulators"

    /// What ticking an offered simulator costs, in the user's words.
    ///
    /// Every other scanner in the package says how its row comes back —
    /// `everyOtherCacheRowSaysHowItComesBack` is the test that pins it — and the device
    /// rows, the only ones that cannot come back at all, said nothing. A 9.2 GB
    /// simulator printed as a bare `[x] 9.2 GB` with no explanation beside it.
    public static let offeredDetail =
        "deleting it destroys the device and every app installed in it, "
        + "with no Trash and no undo; it has to be created and set up again"

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        // simctl already reports dataPathSize, so no du call is needed here.
        let kept = context.protection.keptSimulatorUDID
        // Far more than the single newest device is protected: anything pinned, used
        // in the last `deviceRecentUseDays`, or too close to the newest to tell apart.
        // `simctl delete` is permanent — there is no Trash to drag a simulator back
        // out of — so a device the user was working with last week must not be ticked
        // by default. The resolver carries the reason per device; the fallback to
        // `keptSimulatorUDID` keeps that singular field authoritative even if a caller
        // builds a ProtectionSet whose dictionary is empty.
        let protectedUDIDs = context.protection.protectedSimulatorUDIDs

        return context.devices.simulators.map { device in
            let reason = protectedUDIDs[device.udid]
                ?? (device.udid == kept ? .mostRecentlyUsedDevice : nil)

            // The text comes from the reason itself, never from a catch-all. A
            // catch-all has to guess why a non-kept device survived, and it guessed
            // "the same moment as the one you keep" — false for the newest device
            // whenever a pin names an older one, which is exactly when the newest
            // device is protected but not kept.
            let detail: String?
            switch reason {
            case nil:
                detail = device.lastBootedAt == nil
                    ? "never booted · " + Self.offeredDetail
                    : Self.offeredDetail
            case .bootedDevice:
                // Ahead of every other reason, because it is the only one that cannot be
                // stale: `lastBootedAt` is when the boot started, so a simulator left
                // running for eight days reads as untouched to every other rule.
                detail = "running right now"
            case .pinnedDevice:
                // Ahead of "never booted", because a pinned device the user has not
                // booted yet is still kept and "never booted" would hide why.
                detail = "pinned in settings"
            case _ where device.udid == kept:
                detail = "the simulator you keep"
            case .recentlyUsedDevice(let days):
                detail = "used in the last \(days) days"
            case .mostRecentlyUsedDevice:
                // Carried both by the newest device and by one within
                // `indistinguishableWindow` of it, which the resolver deliberately
                // refuses to order. One sentence has to be true of both, so it is the
                // reason's own words.
                detail = "most recently used"
            case .some(let other):
                // No other reason reaches the device map today. Should one arrive,
                // its own description is the only text guaranteed not to lie.
                detail = other.description
            }

            return CleanupItem(
                id: "\(id)|\(device.udid)",
                scannerID: id, group: group,
                name: device.name,
                detail: detail,
                sizeBytes: device.sizeBytes,
                lastUsed: device.lastBootedAt,
                // `.elevated`, not `.safe`. `ReportText.mark` prints the warning `!` only
                // for `.elevated`, and these are the only rows in the app that cannot be
                // undone at all: a 12.9 GB permanent simulator deletion carried the same
                // mark as a Gradle transform cache, while an 84 MB archive that goes to
                // the Trash carried the warning. `.safe` in this model means "regenerated
                // automatically by a normal build", which a simulator never is.
                risk: .elevated,
                protection: reason,
                method: .deleteSimulator(udid: device.udid))
        }
    }
}

public struct SimulatorRuntimesScanner: CleanupScanner {
    public let id = "ios.runtimes"
    public let group = GroupID.xcodeAndIOS
    public let title = "Simulator runtimes"

    /// What ticking a runtime costs. `simctl runtime delete` is permanent like every
    /// device removal, but unlike a simulator the contents are not the user's — Apple
    /// serves the runtime again, so this says download, not destruction.
    public static let offeredDetail =
        "removed permanently; re-downloaded from Apple, several gigabytes"

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        // A runtime with no reported bundle path cannot be measured, and an
        // unmeasurable item would show as 0 bytes and mislead. Skip it.
        let runtimes = context.devices.runtimes.filter { !$0.bundlePath.isEmpty }
        let sizes = await context.sizeMeasurer.sizes(of: runtimes.map(\.bundlePath))

        return runtimes.map { runtime in
            let size = ScanHelpers.measured(sizes, runtime.bundlePath)
            let build = runtime.buildVersion.isEmpty ? nil : "build \(runtime.buildVersion)"
            return CleanupItem(
                id: "\(id)|\(runtime.identifier)",
                scannerID: id, group: group,
                name: runtime.name,
                detail: [build, Self.offeredDetail].compactMap { $0 }.joined(separator: " · "),
                sizeBytes: size.bytes,
                lastUsed: nil,
                // `.elevated`, for the same reason as the device rows above: permanent,
                // and a multi-gigabyte download from Apple to get back.
                risk: .elevated,
                protection: context.protection.runtimeIdentifiers[runtime.identifier],
                method: .deleteSimulatorRuntime(identifier: runtime.identifier),
                // A runtime whose bundle `du` could not measure is offered unticked. The
                // only runtime on a real dev machine sits on a separate volume and is 17 GB;
                // reported as "0 KB" it would have been ticked with nothing to warn on.
                startsUnticked: size.unmeasured)
        }
    }
}

public struct SimulatorCachesScanner: CleanupScanner {
    public let id = "ios.simulatorCaches"
    public let group = GroupID.xcodeAndIOS
    public let title = "Simulator caches"

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let path = context.homePath("Library/Developer/CoreSimulator/Caches")
        guard context.fileManager.fileExists(atPath: path) else { return [] }

        let sizes = await context.sizeMeasurer.sizes(of: [path])
        let size = ScanHelpers.measured(sizes, path)
        return [ScanHelpers.item(
            scannerID: id, group: group, path: path, name: "Simulator caches",
            detail: "downloaded runtime images and temporary files",
            sizeBytes: size.bytes,
            // This row is the reason a missing measurement cannot be reported as 0: it is
            // genuinely 0 bytes on a real dev machine and genuinely ticked.
            startsUnticked: size.unmeasured)]
    }
}
