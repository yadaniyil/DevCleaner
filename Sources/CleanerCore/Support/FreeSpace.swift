import Foundation

public enum FreeSpace {
    /// Space the system would actually give back to you, matching what Finder
    /// reports. `NSFileSystemFreeSize` overstates this on APFS because it counts
    /// purgeable space that has not been purged.
    public static func availableBytes(forVolumeContaining path: String) throws -> Int64 {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

public enum ByteText {
    /// Compact, human-readable size. Uses decimal units to match Finder.
    ///
    /// One decimal place above a gigabyte, so 57,987,670,016 bytes reads as "58.0 GB"
    /// rather than "57.99 GB". Every size in the tool goes through here, so the totals
    /// and the rows are rounded the same way and cannot disagree with each other.
    public static func short(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        switch value {
        case 1_000_000_000...:
            return String(format: "%.1f GB", value / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.0f MB", value / 1_000_000)
        default:
            return String(format: "%.0f KB", value / 1_000)
        }
    }
}

public enum AgeText {
    /// How long ago `date` was, given the time to treat as now.
    ///
    /// `now` is a parameter rather than a wall-clock read for the same reason every
    /// scanner takes `ScanContext.now`: a test pins it, and nothing here is flaky.
    public static func since(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60:      return "just now"
        case ..<3_600:   return "\(Int(seconds / 60))m ago"
        case ..<86_400:  return "\(Int(seconds / 3_600))h ago"
        default:         return "\(Int(seconds / 86_400))d ago"
        }
    }
}
