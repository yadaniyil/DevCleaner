import Foundation

public struct DerivedDataScanner: CleanupScanner {
    /// The identifier, as a static for the same reason `ProjectBuildOutputScanner` has
    /// one: something outside this file has to recognise these rows. The deck shortens
    /// their names — a derived data folder is `Runner-blblggpuoxuymgejdrqraclibwkw`, and
    /// the 28-letter hash is Xcode's, not the user's — and a literal there would be a
    /// second spelling of a string that is also persisted in
    /// `Settings.alwaysSkipScannerIDs`.
    public static let scannerID = "xcode.derivedData"

    public let id = Self.scannerID
    public let group = GroupID.xcodeAndIOS
    public let title = "Derived data"

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let root = context.homePath("Library/Developer/Xcode/DerivedData")
        let children = ScanHelpers.children(of: root, fileManager: context.fileManager)
            .filter(\.isDirectory)
        let sizes = await context.sizeMeasurer.sizes(of: children.map(\.path))

        return children.map { child in
            let workspace = workspacePath(inEntryAt: child.path, fileManager: context.fileManager)
            // Xcode derives this folder's name hash from the workspace path, so a
            // workspace that is gone can never be built into this folder again. The
            // recorded string still starts with a live project root, which alone would
            // protect gigabytes of derived data that nothing will ever reuse.
            let workspaceExists = workspace.map { context.fileManager.fileExists(atPath: $0) } ?? false
            let owner = workspace.flatMap { path -> (key: String, value: ProtectionReason)? in
                guard workspaceExists else { return nil }
                return context.protection.projects.first {
                    path.hasPrefix($0.key + "/") || path == $0.key
                }
            }

            let detail: String?
            if let owner {
                detail = "kept for \((owner.key as NSString).lastPathComponent)"
            } else if workspace == nil {
                detail = "no matching project"
            } else if !workspaceExists {
                detail = "its project folder is gone"
            } else {
                detail = nil
            }

            let size = ScanHelpers.measured(sizes, child.path)
            return ScanHelpers.item(
                scannerID: id, group: group, path: child.path, name: child.name,
                detail: detail,
                sizeBytes: size.bytes,
                lastUsed: child.modified,
                protection: owner?.value,
                startsUnticked: size.unmeasured)
        }
    }

    private func workspacePath(inEntryAt path: String, fileManager: FileManager) -> String? {
        let plistPath = (path as NSString).appendingPathComponent("info.plist")
        guard let data = fileManager.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["WorkspacePath"] as? String
    }
}

public struct ArchivesScanner: CleanupScanner {
    public let id = "xcode.archives"
    public let group = GroupID.xcodeAndIOS
    public let title = "Archives"

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let root = context.homePath("Library/Developer/Xcode/Archives")
        let cutoff = context.now.addingTimeInterval(-Double(context.settings.archiveAgeDays) * 86_400)

        // Archives are stored two levels deep: Archives/<date>/<name>.xcarchive
        let archives = ScanHelpers.children(of: root, fileManager: context.fileManager)
            .filter(\.isDirectory)
            .flatMap { ScanHelpers.children(of: $0.path, fileManager: context.fileManager) }
            .filter { $0.name.hasSuffix(".xcarchive") }
            .filter { ($0.modified ?? .distantPast) < cutoff }
        let sizes = await context.sizeMeasurer.sizes(of: archives.map(\.path))

        return archives.map { archive in
            let size = ScanHelpers.measured(sizes, archive.path)
            return ScanHelpers.item(
                scannerID: id, group: group, path: archive.path,
                name: archive.name.replacingOccurrences(of: ".xcarchive", with: ""),
                detail: "older than \(context.settings.archiveAgeDays) days",
                sizeBytes: size.bytes,
                lastUsed: archive.modified,
                risk: .elevated,
                startsUnticked: size.unmeasured)
        }
    }
}

/// The symbol caches Xcode copies off a device the first time you build to it — and the
/// one per device it is still using, which is **kept**.
///
/// **Why the keeping rule exists.** `~/Library/Developer/Xcode/iOS DeviceSupport` holds one
/// folder per OS build a device was ever connected on. A real dev machine has four, 27 GB:
/// `iPhone17,2 27.0 (24A435)` — the release the phone is running today — plus two abandoned
/// betas of the same version, and `iPad15,7 26.6 (23G71)`, the only one that iPad ever had.
/// This scanner offered all four, ticked, under the sentence "rebuilt when you next connect
/// a device". That sentence was true and thoroughly misleading: "rebuilt" is Xcode copying
/// about 7 GB of symbols back off the phone over a cable, which is several minutes of
/// "Preparing device for development" before the user's next build can start. The old betas
/// really are dead weight. The current one never was, and the iPad's only folder never was.
///
/// **The rule.** Folders are grouped into families by platform and device model, and in each
/// family the most recently modified one is protected with `.newestDeviceSupport`. A family
/// of one is therefore always kept, which is what covers the iPad. The rest are offered, and
/// their detail says which device they belong to and that Xcode is using a newer one — the
/// fact that makes the offer safe to accept.
public struct DeviceSupportScanner: CleanupScanner {
    public let id = "xcode.deviceSupport"
    public let group = GroupID.xcodeAndIOS
    public let title = "Device support files"

    public init() {}

    /// One folder, with everything needed to file it into a family.
    ///
    /// A named type rather than a tuple because it travels through three steps — grouped,
    /// compared, then turned into a row — and `entry.0.1` at the third one is unreadable.
    struct Candidate {
        let child: ScanHelpers.Child
        /// "iOS" or "watchOS": which of the two directories it came out of.
        let platform: String
        /// The device model Xcode wrote in front of the build, or `nil` — see
        /// `model(inFolderNamed:)`.
        let model: String?

        /// What decides which folders compete with each other.
        ///
        /// Platform **and** model, so a watch and a phone are never in one family even if
        /// some future model identifier collided, and so two devices of the same kind keep
        /// one folder each rather than sharing one. The `nil` model collapses to a single
        /// family per platform, which is the honest reading of a name that does not say
        /// which device it is for: see `model(inFolderNamed:)`.
        var family: String { "\(platform)|\(model ?? "")" }
    }

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let roots = [
            (path: context.homePath("Library/Developer/Xcode/iOS DeviceSupport"), platform: "iOS"),
            (path: context.homePath("Library/Developer/Xcode/watchOS DeviceSupport"), platform: "watchOS"),
        ]
        let candidates = roots.flatMap { root in
            ScanHelpers.children(of: root.path, fileManager: context.fileManager)
                .filter(\.isDirectory)
                // `contentsOfDirectory` promises no order, and the tie-break below and the
                // row order both have to be the same on every scan of the same machine.
                .sorted { $0.name < $1.name }
                .map {
                    Candidate(child: $0, platform: root.platform,
                              model: Self.model(inFolderNamed: $0.name))
                }
        }
        let sizes = await context.sizeMeasurer.sizes(of: candidates.map(\.child.path))

        // The kept folder of each family, by path. A `Set` of paths rather than a dictionary
        // of families, so the loop below asks the one question it needs about each row.
        var kept: Set<String> = []
        for family in Dictionary(grouping: candidates, by: \.family).values {
            if let newest = Self.newest(of: family) { kept.insert(newest.child.path) }
        }

        return candidates.map { candidate in
            let size = ScanHelpers.measured(sizes, candidate.child.path)
            let isKept = kept.contains(candidate.child.path)
            return ScanHelpers.item(
                scannerID: id, group: group, path: candidate.child.path,
                name: "\(candidate.platform) \(candidate.child.name)",
                detail: isKept
                    ? Self.keptDetail(model: candidate.model)
                    : Self.offeredDetail(platform: candidate.platform, model: candidate.model),
                sizeBytes: size.bytes, lastUsed: candidate.child.modified,
                // `.elevated`, not `.safe`. Nothing on this Mac rebuilds it: the symbols
                // come off the device, so getting one back needs that device, still running
                // that exact OS build, plugged in — and for an abandoned beta the source
                // really may be gone, which is what `.elevated` means.
                risk: .elevated,
                protection: isKept ? .newestDeviceSupport : nil,
                startsUnticked: size.unmeasured)
        }
    }

    /// The text on the folder Xcode is using now.
    public static func keptDetail(model: String?) -> String {
        "the one Xcode uses for \(model ?? "this device") now"
    }

    /// The text on an older folder: which device it belongs to, and why letting it go is
    /// safe.
    ///
    /// Two clauses, the same shape as every other sentence in this app that justifies an
    /// offer: the fact ("an older iOS build for iPhone17,2") and then the consequence
    /// ("Xcode uses the newer one"). The fact alone would leave the user weighing 7 GB
    /// against nothing.
    public static func offeredDetail(platform: String, model: String?) -> String {
        "an older \(platform) build for \(model ?? "this device") — Xcode uses the newer one"
    }

    /// The device model Xcode put in front of the build, or `nil` for a name that has none.
    ///
    /// Modern Xcode writes `iPhone17,2 27.0 (24A435)`; older Xcode wrote the build alone,
    /// `16.4 (20F66)`. The discriminator is the first character of the first word: a model
    /// identifier starts with a letter, a version starts with a digit. Grouping the older
    /// names by their first word would make one family per **iOS version** and keep every
    /// single folder — the bug this rule exists to avoid, inverted.
    static func model(inFolderNamed name: String) -> String? {
        let first = name.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard let initial = first.first, initial.isLetter else { return nil }
        return first
    }

    /// The folder in one family that Xcode is using: the most recently modified one.
    ///
    /// The comparator is a strict total order, so there is no ambiguity about which element
    /// `max` returns. Three rules, in the order they are asked:
    ///
    /// 1. **A dated folder always beats an undated one.** An unknown date is not an old
    ///    date, and the safe direction here is to keep something whose age is known rather
    ///    than protect a folder nothing can date and offer the live one.
    /// 2. **Newer modification date wins.** Xcode touches the folder it uses.
    /// 3. **Ties go to the name that sorts last**, which for `(24A435)` against
    ///    `(24A5424a)` is arbitrary but fixed — and fixed is the property that matters,
    ///    because a keeping rule that moved between scans would offer the live folder every
    ///    other time.
    static func newest(of family: [Candidate]) -> Candidate? {
        family.max { left, right in
            switch (left.child.modified, right.child.modified) {
            case (nil, nil):
                return left.child.name < right.child.name
            case (nil, _):
                return true
            case (_, nil):
                return false
            case (let mine?, let theirs?):
                return mine == theirs
                    ? left.child.name < right.child.name
                    : mine < theirs
            }
        }
    }
}
