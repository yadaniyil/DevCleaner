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
        return write(value, in: scale(for: value))
    }

    /// The same size written in the scale **another** size would use: "0.6 GB" for 582 MB
    /// beside a 41.3 GB total.
    ///
    /// For the one place two sizes are printed as a single quantity — the checklist page's
    /// "0.6 of 41.3 GB", what is ticked out of what there is. Each written in its own scale
    /// that pair reads "582 MB of 41.3 GB", which is two facts side by side rather than a part
    /// of a whole: at a glance 582 is the bigger number.
    ///
    /// Here rather than in the deck, beside the thresholds and the decimals it has to agree
    /// with: a second table of divisors written next to a card is a table that rounds 0.55
    /// differently from the total above it.
    public static func short(_ bytes: Int64, inTheScaleOf reference: Int64) -> String {
        write(Double(max(0, bytes)), in: scale(for: Double(max(0, reference))))
    }

    /// One of the three scales `short` writes in: what to divide by, how many decimals, and
    /// the name. Read out of a single table so the two callers above cannot disagree.
    private struct Scale {
        let divisor: Double
        let decimals: Int
        let name: String
    }

    private static func scale(for value: Double) -> Scale {
        switch value {
        case 1_000_000_000...:
            return Scale(divisor: 1_000_000_000, decimals: 1, name: "GB")
        case 1_000_000...:
            return Scale(divisor: 1_000_000, decimals: 0, name: "MB")
        default:
            return Scale(divisor: 1_000, decimals: 0, name: "KB")
        }
    }

    /// Exactly one space between the numeral and the unit — the construction `SizeHeadline`
    /// reads backwards to set the two at different sizes.
    private static func write(_ value: Double, in scale: Scale) -> String {
        String(format: "%.\(scale.decimals)f \(scale.name)", value / scale.divisor)
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
