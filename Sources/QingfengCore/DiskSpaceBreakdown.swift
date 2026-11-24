import Foundation

/// A capacity-based overview, not a separate inventory of system or application files.
public struct DiskSpaceBreakdown: Sendable {
    public let total: Int64
    public let available: Int64
    public let cleanup: Int64?
    public let cleanupWasCapped: Bool

    public init(total: Int64, available: Int64, cleanup: Int64?) {
        self.total = max(0, total)
        self.available = min(max(0, available), self.total)
        let used = self.total - self.available
        // Allocated-block estimates and live volume capacity can disagree (e.g. APFS clones).
        self.cleanup = self.total > 0 ? cleanup.map { min(max(0, $0), used) } : nil
        self.cleanupWasCapped = self.total > 0 && (cleanup ?? 0) > used
    }

    public var hasCapacity: Bool { total > 0 }
    public var used: Int64 { total - available }
    public var otherUsed: Int64 { used - (cleanup ?? 0) }

    /// Every segment and category uses the same denominator: the whole volume.
    public func fraction(of bytes: Int64) -> Double {
        guard hasCapacity else { return 0 }
        return Double(min(max(0, bytes), total)) / Double(total)
    }
}
