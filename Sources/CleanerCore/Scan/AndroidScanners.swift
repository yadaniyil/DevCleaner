import Foundation

public struct AVDScanner: CleanupScanner {
    public let id = "android.avds"
    public let group = GroupID.android
    public let title = "Android emulators"

    /// What ticking an offered emulator costs. The simulator half of this is
    /// `SimulatorDevicesScanner.offeredDetail`, written for the same reason: these are
    /// the only rows in the app that cannot be undone, and they were the only ones with
    /// no explanation beside them at all.
    public static let offeredDetail =
        "deleting it destroys the emulator and every app installed in it, "
        + "with no Trash and no undo; it has to be created and set up again"

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let avds = context.devices.avds
        let sizes = await context.sizeMeasurer.sizes(of: avds.map(\.directoryPath))

        let kept = context.protection.keptAVDName
        // Far more than the single newest emulator is protected: anything pinned, used
        // within `deviceRecentUseDays`, or too close to the newest to tell apart.
        // `avdmanager delete` is permanent — an emulator has no Trash to be dragged back
        // out of — so an emulator the user ran yesterday must not be ticked by default.
        // The resolver carries the reason per emulator; the fallback to `keptAVDName`
        // keeps that singular field authoritative even if a caller builds a
        // ProtectionSet whose dictionary is empty.
        let protectedNames = context.protection.protectedAVDNames

        return avds.map { avd -> CleanupItem in
            let reason = protectedNames[avd.name]
                ?? (avd.name == kept ? .mostRecentlyUsedDevice : nil)

            // The text comes from the reason itself, never from a catch-all. A catch-all
            // has to guess why an emulator that is not the kept one survived, and the
            // guess is wrong for the newest emulator whenever a pin names an older one —
            // exactly when the newest is protected but not kept.
            let detail: String?
            switch reason {
            case nil:
                detail = avd.lastUsed == nil
                    ? "never started · " + Self.offeredDetail
                    : Self.offeredDetail
            case .pinnedDevice:
                // Ahead of "never started", because a pinned emulator the user has not
                // booted yet is still kept and "never started" would hide why.
                detail = "pinned in settings"
            case _ where avd.name == kept:
                detail = "the emulator you keep"
            case .recentlyUsedDevice(let days):
                detail = "used in the last \(days) days"
            case .mostRecentlyUsedDevice:
                // Carried both by the newest emulator and by one within
                // `indistinguishableWindow` of it, which the resolver deliberately
                // refuses to order. One sentence has to be true of both, so it is the
                // reason's own words.
                detail = "most recently used"
            case .some(let other):
                // No other reason reaches the device map today. Should one arrive, its
                // own description is the only text guaranteed not to lie.
                detail = other.description
            }

            let size = ScanHelpers.measured(sizes, avd.directoryPath)
            return CleanupItem(
                id: "\(id)|\(avd.name)",
                scannerID: id, group: group,
                name: avd.name,
                detail: detail,
                sizeBytes: size.bytes,
                lastUsed: avd.lastUsed,
                // `.elevated`, not `.safe` — see the matching comment in
                // `SimulatorDevicesScanner`. `ReportText.mark` prints `!` only for
                // `.elevated`, and this row is permanent.
                risk: .elevated,
                protection: reason,
                method: .deleteAVD(name: avd.name),
                startsUnticked: size.unmeasured)
        }
    }
}

public struct SystemImagesScanner: CleanupScanner {
    public let id = "android.systemImages"
    public let group = GroupID.android
    public let title = "Android system images"

    private struct Image {
        let name: String
        let path: String
        let modified: Date?
        /// What `image.sysdir.1` holds for this image, relative to the SDK root.
        var relative: String { "system-images/" + name }
    }

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let root = (context.androidSDKPath as NSString).appendingPathComponent("system-images")

        // system-images/<api>/<variant>/<abi> — the ABI directory is the unit the SDK
        // manager installs and removes. Sorted so the list does not reshuffle between
        // scans; `contentsOfDirectory` promises no order.
        var images: [Image] = []
        for api in directories(in: root, context) {
            for variant in directories(in: api.path, context) {
                for abi in directories(in: variant.path, context) {
                    images.append(Image(
                        name: "\(api.name)/\(variant.name)/\(abi.name)",
                        path: abi.path,
                        modified: abi.modified))
                }
            }
        }
        images.sort { $0.name < $1.name }

        // Every emulator that survives a default clean, not only the kept one. An
        // emulator used three days ago is protected but is not `keptAVDName`, and
        // deleting the image underneath it leaves an emulator that is still installed
        // and no longer boots — a failure the user meets much later, with nothing to
        // undo. The fallback keeps the singular field authoritative for a hand-built set.
        var survivingAVDNames = Set(context.protection.protectedAVDNames.keys)
        if let kept = context.protection.keptAVDName { survivingAVDNames.insert(kept) }

        let sizes = await context.sizeMeasurer.sizes(of: images.map(\.path))

        return images.map { image in
            let users = context.devices.avds
                .filter { Self.sysdir($0.systemImageRelativePath, refersTo: image.relative) }
                .map(\.name)
                .sorted()
            let keeper = users.first { survivingAVDNames.contains($0) }

            let size = ScanHelpers.measured(sizes, image.path)
            return ScanHelpers.item(
                scannerID: id, group: group, path: image.path, name: image.name,
                // True whether or not the emulators naming it survive. An image whose
                // only user is itself offered stays deletable, but the user is about to
                // tick two rows and has to see that they belong together.
                detail: users.isEmpty
                    ? "no emulator uses it"
                    : "used by \(users.joined(separator: ", "))",
                sizeBytes: size.bytes,
                lastUsed: image.modified,
                // Reinstalling one is a multi-gigabyte `sdkmanager` download.
                risk: .elevated,
                protection: keeper.map { .sdkInUse(by: $0) },
                startsUnticked: size.unmeasured)
        }
    }

    /// `image.sysdir.1` is documented as relative to the SDK root, and that is what all
    /// four emulators on a real dev machine contain. Some tooling writes it absolute, so a
    /// suffix is accepted as well — with the separator required, so that
    /// `…/android-3/google_apis/x86` cannot satisfy `android-34/google_apis/x86`.
    static func sysdir(_ value: String?, refersTo relative: String) -> Bool {
        guard let value else { return false }
        return value == relative || value.hasSuffix("/" + relative)
    }

    private func directories(in path: String, _ context: ScanContext) -> [ScanHelpers.Child] {
        ScanHelpers.children(of: path, fileManager: context.fileManager).filter(\.isDirectory)
    }
}

/// The Android NDK, one row per installed version.
///
/// The only scanner in this package whose rows are **offered but not ticked**. The NDK
/// is 5.57 GB on a real dev machine across two versions, it goes to the Trash like any folder,
/// and Android Studio downloads it again the first time a build needs native code. Two
/// facts pull in opposite directions: most projects never build native code, so for most
/// users this is pure dead weight; and for the user who does, the cost of a wrong tick is
/// a multi-gigabyte download at the moment they wanted to build. So it is shown with its
/// size and left for the user to tick deliberately — `CleanupItem.startsUnticked`.
///
/// One row per version directory, never one row for `ndk` itself. Two versions are
/// installed here and a user who is keeping one of them must be able to hand back the
/// other; a single row makes that choice impossible.
///
/// **`<androidSDKPath>/ndk` is an allowed root of `PathGuard.forRun`.** Task 17 left it
/// out on purpose when no scanner produced it. Without that root every row below is
/// refused after the user ticks it and the app frees nothing at all.
public struct NDKScanner: CleanupScanner {
    public let id = "android.ndk"
    public let group = GroupID.android
    public let title = "Android NDK"

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let root = (context.androidSDKPath as NSString).appendingPathComponent("ndk")

        // Directories only: `~/Library/Android/sdk/ndk` also holds the plain files the
        // SDK manager writes beside the versions, and a file offered under the name of a
        // three-gigabyte folder would measure as zero. Sorted, because
        // `contentsOfDirectory` promises no order and a list that reshuffles between
        // scans moves the tick boxes under the user's cursor.
        let versions = ScanHelpers.children(of: root, fileManager: context.fileManager)
            .filter(\.isDirectory)
            .sorted { $0.name < $1.name }

        let sizes = await context.sizeMeasurer.sizes(of: versions.map(\.path))

        return versions.map { version in
            ScanHelpers.item(
                scannerID: id, group: group, path: version.path, name: version.name,
                detail: "Android Studio downloads it again when a build needs native code",
                sizeBytes: ScanHelpers.measured(sizes, version.path).bytes,
                lastUsed: version.modified,
                // Gigabytes, over the network, and no build works until it finishes.
                risk: .elevated,
                // Already unticked whatever the measurement said, so there is nothing for
                // `measured(_:_:).unmeasured` to add here.
                startsUnticked: true)
        }
    }
}

public struct GradleScanner: CleanupScanner {
    public let id = "android.gradle"
    public let group = GroupID.android
    public let title = "Gradle"

    public init() {}

    private struct Candidate {
        let path: String
        let name: String
        let detail: String?
        let risk: RiskLevel
        let protection: ProtectionReason?
    }

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let gradleHome = context.homePath(".gradle")
        let caches = (gradleHome as NSString).appendingPathComponent("caches")

        // One listing, directories only. `~/.gradle/caches` also holds `CACHEDIR.TAG`
        // and per-version metadata folders such as `8.14` and `journal-1`, none of which
        // this scanner touches.
        let cacheDirectories = ScanHelpers.children(of: caches, fileManager: context.fileManager)
            .filter(\.isDirectory)

        var candidates: [Candidate] = []

        // Fixed cache directories, named in plain words for the UI, in a fixed order.
        let named: [(directory: String, name: String, detail: String, risk: RiskLevel)] = [
            ("modules-2", "Downloaded dependencies", "re-downloaded on the next build", .elevated),
            ("build-cache-1", "Build cache", "rebuilt on the next build", .safe),
        ]
        for entry in named {
            guard let child = cacheDirectories.first(where: { $0.name == entry.directory })
            else { continue }
            candidates.append(Candidate(
                path: child.path, name: entry.name, detail: entry.detail,
                risk: entry.risk, protection: nil))
        }

        // Version-suffixed cache directories: transforms-3, jars-9, and so on. The
        // number changes with the Gradle version, so they cannot be listed by name.
        for child in cacheDirectories.sorted(by: { $0.name < $1.name })
        where child.name.hasPrefix("transforms-")
            || child.name.hasPrefix("jars-")
            || child.name.hasPrefix("journal-") {
            candidates.append(Candidate(
                path: child.path, name: child.name,
                detail: "regenerated on the next build", risk: .safe, protection: nil))
        }

        if let daemon = ScanHelpers.children(of: gradleHome, fileManager: context.fileManager)
            .first(where: { $0.name == "daemon" && $0.isDirectory }) {
            candidates.append(Candidate(
                path: daemon.path, name: "Daemon logs",
                detail: "logs from background Gradle processes", risk: .safe, protection: nil))
        }

        // Wrapper distributions, one folder per distribution. The folder name is the zip
        // name minus `.zip`, which is exactly the key `ProtectionResolver` records — so
        // the comparison is a plain lookup with no second parse to drift out of sync.
        let dists = (gradleHome as NSString).appendingPathComponent("wrapper/dists")
        for child in ScanHelpers.children(of: dists, fileManager: context.fileManager)
            .filter(\.isDirectory)
            .sorted(by: { $0.name < $1.name }) {
            candidates.append(Candidate(
                path: child.path, name: child.name, detail: "Gradle distribution",
                // Roughly 150 MB back over the network on the next build of any project
                // that names it.
                risk: .elevated,
                protection: context.protection.gradleDistributions[child.name]))
        }

        let sizes = await context.sizeMeasurer.sizes(of: candidates.map(\.path))

        return candidates.map { candidate in
            let size = ScanHelpers.measured(sizes, candidate.path)
            return ScanHelpers.item(
                scannerID: id, group: group, path: candidate.path, name: candidate.name,
                detail: candidate.detail, sizeBytes: size.bytes,
                risk: candidate.risk, protection: candidate.protection,
                startsUnticked: size.unmeasured)
        }
    }
}
