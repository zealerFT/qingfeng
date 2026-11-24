import Foundation

/// A capacity-based overview, not a separate inventory of system or application files.
public struct DiskSpaceBreakdown: Sendable {
    public let total: Int64
    public let available: Int64
    public let cleanup: Int64?
    public let cleanupWasCapped: Bool
    public let free: Int64

    public init(total: Int64, available: Int64, cleanup: Int64?, free: Int64? = nil) {
        self.total = max(0, total)
        self.available = min(max(0, available), self.total)
        self.free = min(max(0, free ?? available), self.available)
        let used = self.total - self.available
        // Allocated-block estimates and live volume capacity can disagree (e.g. APFS clones).
        self.cleanup = self.total > 0 ? cleanup.map { min(max(0, $0), used) } : nil
        self.cleanupWasCapped = self.total > 0 && (cleanup ?? 0) > used
    }

    public var hasCapacity: Bool { total > 0 }
    public var used: Int64 { total - available }
    public var otherUsed: Int64 { used - (cleanup ?? 0) }
    public var reclaimable: Int64 { available - free }

    /// Every segment and category uses the same denominator: the whole volume.
    public func fraction(of bytes: Int64) -> Double {
        guard hasCapacity else { return 0 }
        return Double(min(max(0, bytes), total)) / Double(total)
    }
}

public struct VolumeCapacity: Sendable {
    public let total: Int64
    public let free: Int64
    public let available: Int64
    public let includesReclaimable: Bool

    public init(total: Int64, free: Int64, importantUsage: Int64?) {
        self.total = max(0, total)
        self.free = min(max(0, free), self.total)
        includesReclaimable = importantUsage != nil && (importantUsage ?? -1) >= 0
        available = min(self.total, max(self.free, includesReclaimable ? importantUsage! : self.free))
    }

    public static func read(at url: URL) throws -> VolumeCapacity {
        let basic = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let important = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return VolumeCapacity(total: Int64(basic.volumeTotalCapacity ?? 0),
                              free: Int64(basic.volumeAvailableCapacity ?? 0),
                              importantUsage: important?.volumeAvailableCapacityForImportantUsage)
    }
}
