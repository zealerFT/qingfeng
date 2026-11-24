import QingfengCore

extension CleanerTests {
    func testDiskBreakdownAccountsForTheWholeVolume() {
        let space = DiskSpaceBreakdown(total: 1_000, available: 200, cleanup: 125)
        expectEqual(space.used, 800)
        expectEqual(space.otherUsed, 675)
        expectEqual((space.cleanup ?? 0) + space.otherUsed + space.available, space.total)
        expectEqual(space.fraction(of: space.cleanup ?? 0), 0.125)
        expectEqual(space.fraction(of: space.otherUsed), 0.675)
        expectEqual(space.fraction(of: space.available), 0.2)
        expectFalse(space.cleanupWasCapped)
    }

    func testDiskBreakdownDistinguishesUnscannedFromEmpty() {
        let unscanned = DiskSpaceBreakdown(total: 1_000, available: 200, cleanup: nil)
        let scanned = DiskSpaceBreakdown(total: 1_000, available: 200, cleanup: 0)
        expectEqual(unscanned.cleanup, nil)
        expectEqual(scanned.cleanup, 0)
        expectEqual(unscanned.otherUsed, 800)
        expectEqual(scanned.otherUsed, 800)
    }

    func testDiskBreakdownHandlesUnknownCapacity() {
        for total: Int64 in [0, -1] {
            let space = DiskSpaceBreakdown(total: total, available: 200, cleanup: 125)
            expectFalse(space.hasCapacity)
            expectEqual(space.cleanup, nil)
            expectEqual(space.used, 0)
            expectEqual(space.otherUsed, 0)
            expectEqual(space.available, 0)
            expectEqual(space.fraction(of: 125), 0)
        }
    }

    func testDiskBreakdownBoundsStaleOrSharedStorageEstimates() {
        let stale = DiskSpaceBreakdown(total: 1_000, available: 200, cleanup: 1_200)
        expectEqual(stale.cleanup, 800)
        expectEqual(stale.otherUsed, 0)
        expectTrue(stale.cleanupWasCapped)
        let empty = DiskSpaceBreakdown(total: 1_000, available: 1_200, cleanup: 0)
        expectEqual(empty.available, empty.total)
        expectEqual(empty.otherUsed, 0)
        let negative = DiskSpaceBreakdown(total: 1_000, available: -200, cleanup: -125)
        expectEqual(negative.available, 0)
        expectEqual(negative.cleanup, 0)
        expectEqual(negative.otherUsed, 1_000)
        // No subtraction overflow or out-of-range ring segments at integer boundaries.
        let extreme = DiskSpaceBreakdown(total: .max, available: .min, cleanup: .max)
        expectEqual(extreme.cleanup, .max)
        expectEqual(extreme.otherUsed, 0)
        expectEqual(extreme.fraction(of: .max), 1)
        expectEqual(extreme.fraction(of: .min), 0)
    }
}
