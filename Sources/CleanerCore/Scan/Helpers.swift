import Foundation

public enum ScanHelpers {
    public struct Child: Sendable, Equatable {
        public let name: String
        public let path: String
        public let isDirectory: Bool
        public let modified: Date?
    }

    /// Immediate children of a directory, hidden entries excluded. A missing or
    /// unreadable directory yields an empty list rather than an error.
    public static func children(of directory: String, fileManager: FileManager = .default) -> [Child] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let path = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            return Child(
                name: name, path: path, isDirectory: isDirectory.boolValue,
                modified: attributes?[.modificationDate] as? Date)
        }
    }

    /// What `SizeMeasuring` answered for one path: the size to show, and whether it
    /// could be measured at all.
    ///
    /// A missing key is **not** zero. `du` may not have run, or may have printed
    /// something with no number in it, and the tool then does not know how big the thing
    /// is. Zero cannot carry both meanings, because `ios.simulatorCaches` really is 0
    /// bytes here and really is ticked.
    ///
    /// An unmeasured row is offered with `startsUnticked`, so it appears in the listing
    /// and stays out of a default clean. Ticking a row whose size is unknown is asking
    /// the user to approve a deletion neither of you can size — and the one runtime on
    /// a real dev machine sits on a separate volume and is 17 GB.
    public static func measured(
        _ sizes: [String: Int64], _ path: String
    ) -> (bytes: Int64, unmeasured: Bool) {
        guard let bytes = sizes[path] else { return (0, true) }
        return (bytes, false)
    }

    /// Builds a path-removal item. Used by most scanners so identifiers and
    /// defaults stay consistent across them.
    public static func item(
        scannerID: String, group: GroupID, path: String, name: String,
        detail: String? = nil, sizeBytes: Int64, lastUsed: Date? = nil,
        risk: RiskLevel = .safe, protection: ProtectionReason? = nil,
        startsUnticked: Bool = false, sizeMayBeShared: Bool = false
    ) -> CleanupItem {
        CleanupItem(
            id: "\(scannerID)|\(path)", scannerID: scannerID, group: group,
            name: name, detail: detail, sizeBytes: sizeBytes, lastUsed: lastUsed,
            risk: risk, protection: protection, method: .removePath(path),
            startsUnticked: startsUnticked, sizeMayBeShared: sizeMayBeShared)
    }
}
