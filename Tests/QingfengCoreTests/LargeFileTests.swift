import Foundation
import QingfengCore

extension CleanerTests {
    func testLargeFileBatchMovesOnlySelectedFilesAndRecordsResults() throws {
        let first = try file("Downloads/first/video.mov")
        let second = try file("Downloads/second/video.mov")
        let keep = try file("Downloads/keep.bin")
        let report = DiskScanner(home: root).largeFiles(roots: [root.appendingPathComponent("Downloads")], minimum: 1)
        expectEqual(report.items.count, 3)
        expectTrue(report.items.allSatisfy { $0.eligible && !$0.suggested })
        expectEqual(report.cleanableBytes, 0) // Personal files are not cache-cleanup estimates.
        let selectedPaths = Set([first, second].map { $0.standardizedFileURL.path })
        let selected = report.items.filter { selectedPaths.contains($0.path) }
        expectEqual(selected.count, 2)
        var journal: [CleanupEntry] = []
        var calls = 0
        let entries = Cleaner(home: root).clean(selected, onEntry: { journal.append($0) }, trash: { url in
            calls += 1
            let destination = self.root.appendingPathComponent("trashed-\(calls)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
        expectEqual(calls, 2)
        expectEqual(entries.count, 2)
        expectTrue(entries.allSatisfy(\.success))
        expectEqual(Set(journal.map(\.source)), selectedPaths)
        expectTrue(journal.allSatisfy { $0.destination != nil && $0.bytes > 0 })
        expectFalse(FileManager.default.fileExists(atPath: first.path))
        expectFalse(FileManager.default.fileExists(atPath: second.path))
        expectEqual(try String(contentsOf: keep, encoding: .utf8), "temporary synthetic fixture")
    }

    func testChangedMissingOrReplacedLargeFilesAreSkipped() throws {
        let modified = try file("Downloads/modified.bin", data: "original")
        let linked = try file("Downloads/linked.bin")
        let missing = try file("Downloads/missing.bin")
        let directory = try file("Downloads/directory.bin")
        let keep = try file("Documents/keep.bin")
        let report = DiskScanner(home: root).largeFiles(roots: [root.appendingPathComponent("Downloads")], minimum: 1)
        try Data("modified".utf8).write(to: modified)
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: keep)
        try FileManager.default.removeItem(at: missing)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var calls = 0
        let entries = Cleaner(home: root).clean(report.items, trash: { url in calls += 1; return url })
        expectEqual(entries.count, 4)
        expectTrue(entries.allSatisfy { !$0.success && $0.destination == nil })
        expectEqual(calls, 0)
        expectEqual(try String(contentsOf: keep, encoding: .utf8), "temporary synthetic fixture")
    }

    func testLargeFileProtectedPathsRemainReadOnly() throws {
        let policy = SafetyPolicy(home: root)
        let paths = [
            ".ollama/models/model.bin", ".cache/huggingface/model.bin", ".local/share/containers/disk.bin",
            "Library/Application Support/MobileSync/Backup/backup.bin", "Library/Developer/Xcode/Archives/archive.bin",
            "Library/Caches/JetBrains/GoLand/LocalHistory/history.bin", "Applications/Tool.app/Contents/data.bin",
            "Downloads/Tool.app/Contents/data.bin", "Documents/Photos.photoslibrary/originals/photo.bin",
            "Projects/demo/node_modules/module/data.bin", "Projects/demo/Pods/module/data.bin",
            "Documents/.hidden.bin", "Downloads/.private/data.bin", "Documents/cloud.icloud"
        ]
        for path in paths {
            let url = try file(path)
            expectFalse(policy.allows(url, category: .large))
            expectThrows(try Cleaner(home: root).validate(item(path, category: .large)))
            let report = DiskScanner(home: root).largeFiles(roots: [url.deletingLastPathComponent()], minimum: 1)
            expectTrue(report.items.allSatisfy { !$0.eligible })
        }
        expectFalse(policy.allows(root.appendingPathComponent("Downloads"), category: .large))
        let otherHome = root.appendingPathComponent("other-home")
        try FileManager.default.createDirectory(at: otherHome, withIntermediateDirectories: true)
        let ordinary = try file("Documents/ordinary.bin")
        let outside = DiskScanner(home: otherHome).largeFiles(roots: [root.appendingPathComponent("Documents")], minimum: 1)
        expectTrue(outside.items.contains { $0.title == ordinary.lastPathComponent })
        expectTrue(outside.items.allSatisfy { !$0.eligible })
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("Documents"))
        expectFalse(policy.allows(alias.appendingPathComponent(ordinary.lastPathComponent), category: .large))
    }

    func testLargeFileWithoutSnapshotCannotBeDeleted() throws {
        let original = try file("Downloads/no-snapshot.bin")
        let candidate = item("Downloads/no-snapshot.bin", category: .large)
        var measurement = candidate.measurement
        measurement.entries.removeAll()
        let incomplete = ScanItem(path: candidate.path, title: candidate.title, category: .large, note: "fixture",
                                  measurement: measurement, eligible: true, suggested: false)
        var calls = 0
        let entries = Cleaner(home: root).clean([incomplete], trash: { url in calls += 1; return url })
        expectEqual(calls, 0)
        expectFalse(try require(entries.first).success)
        expectTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testLargeFileBatchContinuesAfterTrashFailure() throws {
        let denied = try file("Downloads/denied.bin")
        let moved = try file("Downloads/moved.bin")
        let destination = root.appendingPathComponent("trashed.bin")
        var journal: [CleanupEntry] = []
        let entries = Cleaner(home: root).clean(
            [item("Downloads/denied.bin", category: .large), item("Downloads/moved.bin", category: .large)],
            onEntry: { journal.append($0) }, trash: { url in
                if url == denied { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            })
        expectEqual(entries.map(\.success), [false, true])
        expectEqual(journal.count, 2)
        expectTrue(FileManager.default.fileExists(atPath: denied.path))
        expectFalse(FileManager.default.fileExists(atPath: moved.path))
        expectTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testLargeFileBatchCancellationLeavesRemainingFiles() throws {
        try file("Downloads/first.bin")
        let keep = try file("Downloads/keep.bin")
        let targets = [item("Downloads/first.bin", category: .large), item("Downloads/keep.bin", category: .large)]
        let flag = CancellationFlag()
        var calls = 0
        let entries = Cleaner(home: root).clean(targets, cancellation: flag, onEntry: { _ in flag.cancel() }, trash: { url in
            calls += 1
            let destination = self.root.appendingPathComponent("trashed.bin")
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
        expectEqual(calls, 1)
        expectEqual(entries.count, 1)
        expectTrue(try require(entries.first).success)
        expectTrue(FileManager.default.fileExists(atPath: keep.path))
    }

    func testLargeFileSystemTrashAndRestore() throws {
        let original = try file("Downloads/qingfeng-large-fixture-\(UUID().uuidString).bin")
        let report = DiskScanner(home: root).largeFiles(roots: [original.deletingLastPathComponent()], minimum: 1)
        let entry = try require(Cleaner(home: root).clean(report.items).first)
        expectTrue(entry.success)
        guard entry.success, let path = entry.destination else {
            throw NSError(domain: "TrashIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: entry.message])
        }
        let moved = URL(fileURLWithPath: path)
        defer { try? FileManager.default.moveItem(at: moved, to: original) }
        expectFalse(FileManager.default.fileExists(atPath: original.path))
        expectEqual(try String(contentsOf: moved, encoding: .utf8), "temporary synthetic fixture")
        try FileManager.default.moveItem(at: moved, to: original)
        expectTrue(FileManager.default.fileExists(atPath: original.path))
    }
}
