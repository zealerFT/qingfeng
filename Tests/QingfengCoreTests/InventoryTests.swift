import Foundation
import QingfengCore

extension CleanerTests {
    func testCapacitySeparatesFreeAndSystemReclaimable() {
        let capacity = VolumeCapacity(total: 1_000, free: 50, importantUsage: 100)
        expectEqual(capacity.available, 100)
        expectTrue(capacity.includesReclaimable)
        let space = DiskSpaceBreakdown(total: capacity.total, available: capacity.available, cleanup: 80, free: capacity.free)
        expectEqual(space.free, 50); expectEqual(space.reclaimable, 50)
        expectEqual(space.used, 900); expectEqual(space.otherUsed, 820)
        expectEqual(space.free + space.reclaimable, space.available)
        let fallback = VolumeCapacity(total: 1_000, free: 50, importantUsage: nil)
        expectEqual(fallback.available, 50); expectFalse(fallback.includesReclaimable)
        expectEqual(VolumeCapacity(total: 1_000, free: 50, importantUsage: -1).available, 50)
        expectEqual(VolumeCapacity(total: 1_000, free: 50, importantUsage: 20).available, 50)
        expectEqual(VolumeCapacity(total: 1_000, free: 50, importantUsage: 2_000).available, 1_000)
    }
    func testHomeInventoryFindsHiddenModelsAndCustomFolders() throws {
        let paths = [".ollama/models/blobs/weights", ".cache/huggingface/weights.safetensors",
                     "Library/Application Support/Example/model.gguf", "Work/models/checkpoint.pth", "Music/song.flac"]
        for path in paths { try file(path) }
        let scanner = DiskScanner(home: root)
        expectEqual(scanner.defaultLargeRoots.map(\.path), [root.path])
        let result = scanner.largeFiles(roots: scanner.defaultLargeRoots, minimum: 1)
        expectEqual(result.items.count, paths.count)
        expectEqual(result.items.filter { $0.fileKind == .models }.count, 4)
        expectFalse(try require(result.items.first { $0.path.contains("/.ollama/") }).eligible)
        expectFalse(try require(result.items.first { $0.path.contains("/Library/") }).eligible)
        expectTrue(try require(result.items.first { $0.path.contains("/Work/") }).eligible)
        expectTrue(try require(result.largeFileSummary).complete)
    }
    func testInventoryNoLongerSilentlyDropsAfterTwoHundred() throws {
        for index in 0..<230 { try file("Data/item-\(index).bin") }
        let result = DiskScanner(home: root).largeFiles(roots: [root], minimum: 1)
        expectEqual(result.items.count, 230)
        expectEqual(result.largeFileSummary?.matchedFiles, 230)
        expectEqual(result.largeFileSummary?.reachedResultLimit, false)
        let limited = DiskScanner(home: root).largeFiles(roots: [root], minimum: 1, resultLimit: 20)
        expectEqual(limited.items.count, 20)
        expectEqual(limited.largeFileSummary?.matchedFiles, 230)
        expectEqual(limited.largeFileSummary?.reachedResultLimit, true)
        expectTrue(limited.issues.contains { $0.category == .limit })
    }
    func testInventoryReportsEntryLimitsAndCancellation() throws {
        for index in 0..<12 { try file("item-\(index).bin") }
        let limited = DiskScanner(home: root).largeFiles(roots: [root], minimum: 1, entryLimit: 5)
        expectEqual(limited.largeFileSummary?.visitedEntries, 5)
        expectEqual(limited.largeFileSummary?.reachedEntryLimit, true)
        expectEqual(limited.largeFileSummary?.complete, false)
        let exact = DiskScanner(home: root).largeFiles(roots: [root], minimum: 1, entryLimit: 12)
        expectEqual(exact.largeFileSummary?.reachedEntryLimit, false)
        let flag = CancellationFlag(); flag.cancel()
        let stopped = DiskScanner(home: root, cancellation: flag).largeFiles(roots: [root], minimum: 1)
        expectTrue(stopped.cancelled); expectEqual(stopped.largeFileSummary?.complete, false)
    }
    func testInventoryDistinguishesSparseSizeAndAllocatedBlocks() throws {
        let url = try file("Documents/sparse.img", data: "")
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 60_000_000); try handle.close()
        let result = DiskScanner(home: root).largeFiles(roots: [root], minimum: 50_000_000)
        let found = try require(result.items.first)
        expectEqual(found.logicalBytes, 60_000_000)
        expectTrue(found.bytes < found.fileSize)
        expectNoThrow(try Cleaner(home: root).validate(found))
    }
    func testInventoryPackagesCloudPlaceholdersAndOverlappingRoots() throws {
        try file("Applications/Example.app/Contents/data.bin")
        try file("Downloads/cloud.icloud")
        try file("Documents/keep.pdf")
        let result = DiskScanner(home: root).largeFiles(roots: [root, root.appendingPathComponent("Documents")], minimum: 1)
        expectEqual(result.items.count, 2)
        let app = try require(result.items.first { $0.fileKind == .applications })
        expectFalse(app.eligible)
        expectEqual(result.largeFileSummary?.roots.count, 1)
        expectEqual(result.largeFileSummary?.skippedCloudFiles, 1)
        expectFalse(result.items.contains { $0.title == "data.bin" })
        expectThrows(try Cleaner(home: root).validate(app))
    }
}
