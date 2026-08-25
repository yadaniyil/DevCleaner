import Foundation

public struct DerivedDataScanner: CleanupScanner {
    public let id = "xcode.derivedData"
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

public struct DeviceSupportScanner: CleanupScanner {
    public let id = "xcode.deviceSupport"
    public let group = GroupID.xcodeAndIOS
    public let title = "Device support files"

    public init() {}

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let roots = [
            (path: context.homePath("Library/Developer/Xcode/iOS DeviceSupport"), platform: "iOS"),
            (path: context.homePath("Library/Developer/Xcode/watchOS DeviceSupport"), platform: "watchOS"),
        ]
        let children = roots.flatMap { root in
            ScanHelpers.children(of: root.path, fileManager: context.fileManager)
                .filter(\.isDirectory)
                .map { (child: $0, platform: root.platform) }
        }
        let sizes = await context.sizeMeasurer.sizes(of: children.map { $0.child.path })

        return children.map { entry in
            let size = ScanHelpers.measured(sizes, entry.child.path)
            return ScanHelpers.item(
                scannerID: id, group: group, path: entry.child.path,
                name: "\(entry.platform) \(entry.child.name)",
                detail: "rebuilt when you next connect a device",
                sizeBytes: size.bytes, lastUsed: entry.child.modified,
                startsUnticked: size.unmeasured)
        }
    }
}
