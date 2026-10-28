import Foundation
import QingfengCore

final class CleanerTests {
    var root: URL!
    func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qingfeng-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }
    @discardableResult func file(_ path: String, data: String = "temporary synthetic fixture") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(data.utf8).write(to: url)
        return url
    }
    func item(_ path: String, category: ScanCategory = .cache) -> ScanItem {
        let url = root.appendingPathComponent(path)
        return ScanItem(path: url.path, title: url.lastPathComponent, category: category, note: "fixture",
                        measurement: DiskScanner(home: root).measure(url), eligible: true, suggested: false)
    }
    func testUnchangedCacheValidates() throws {
        try file("Library/Caches/test-app/a")
        expectNoThrow(try Cleaner(home: root).validate(item("Library/Caches/test-app")))
    }
    func testChangedNestedFileRejectedEvenSameLength() throws {
        let url = try file("Library/Caches/test-app/a", data: "first")
        let candidate = item("Library/Caches/test-app")
        try Data("other".utf8).write(to: url)
        expectThrows(try Cleaner(home: root).validate(candidate))
    }
    func testAddedFileRejected() throws {
        try file("Library/Caches/test-app/a")
        let candidate = item("Library/Caches/test-app")
        try file("Library/Caches/test-app/new")
        expectThrows(try Cleaner(home: root).validate(candidate))
    }
    func testDeletedNestedFileRejected() throws {
        let url = try file("Library/Caches/test-app/a")
        let candidate = item("Library/Caches/test-app")
        try FileManager.default.removeItem(at: url)
        expectThrows(try Cleaner(home: root).validate(candidate))
    }
    func testSymlinkTargetAndAncestorRejected() throws {
        let secret = try file("Documents/valuable.txt")
        let link = root.appendingPathComponent("Library/Caches/link")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        expectFalse(SafetyPolicy(home: root).allows(link, category: .cache))
        let cache = root.appendingPathComponent(".cache")
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: root.appendingPathComponent("Documents"))
        try file("Documents/uv/x")
        expectFalse(SafetyPolicy(home: root).allows(cache.appendingPathComponent("uv"), category: .developer))
    }
    func testNestedSymlinkPreventsCleanupAndIsNotTraversed() throws {
        let secret = try file("Documents/secret")
        try file("Library/Caches/test-app/a")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Library/Caches/test-app/link"), withDestinationURL: secret)
        let candidate = item("Library/Caches/test-app")
        expectTrue(candidate.measurement.unsafeEntries)
        expectEqual(candidate.measurement.files, 1)
        expectThrows(try Cleaner(home: root).validate(candidate))
    }
    func testPathPrefixCannotEscapeHome() {
        expectFalse(SafetyPolicy.isWithin(root.path + "-neighbor/a", root.path))
        expectFalse(SafetyPolicy(home: root).allows(URL(fileURLWithPath: "/System/Library/Caches"), category: .cache))
        expectFalse(SafetyPolicy(home: root).allows(root, category: .cache))
    }
    func testCacheRootAndArbitraryDocumentsProtected() throws {
        try file("Library/Caches/app/a"); try file("Documents/a")
        let p = SafetyPolicy(home: root)
        expectFalse(p.allows(root.appendingPathComponent("Library/Caches"), category: .cache))
        expectFalse(p.allows(root.appendingPathComponent("Documents/a"), category: .cache))
    }
    func testJetBrainsHistoryAndAppleCachesProtected() throws {
        for path in ["Library/Caches/JetBrains/GoLand/LocalHistory/x", "Library/Caches/com.apple.test/a", "Library/Caches/JetBrains/GoLand/index/x"] { try file(path) }
        let p = SafetyPolicy(home: root)
        expectFalse(p.allows(root.appendingPathComponent("Library/Caches/JetBrains"), category: .cache))
        expectFalse(p.allows(root.appendingPathComponent("Library/Caches/JetBrains/GoLand/LocalHistory"), category: .developer))
        expectFalse(p.allows(root.appendingPathComponent("Library/Caches/com.apple.test"), category: .cache))
        expectTrue(p.allows(root.appendingPathComponent("Library/Caches/JetBrains/GoLand/index"), category: .developer))
    }
    func testModelsAndContainersNeverCleanable() throws {
        for path in [".cache/huggingface/a", ".cache/lm-studio/a", ".ollama/models/a", ".local/share/containers/a"] {
            let url = try file(path)
            for category in ScanCategory.allCases { expectFalse(SafetyPolicy(home: root).allows(url.deletingLastPathComponent(), category: category)) }
        }
    }
    func testInstallerNeedsAgeExtensionAndDownloadsRoot() throws {
        let old = Date().addingTimeInterval(-31 * 86400)
        let installer = try file("Downloads/setup.dmg")
        let archive = try file("Downloads/project.zip")
        let nested = try file("Downloads/project/setup.dmg")
        let p = SafetyPolicy(home: root)
        expectFalse(p.allows(installer, category: .installers))
        for url in [installer, archive, nested] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        expectTrue(p.allows(installer, category: .installers))
        expectFalse(p.allows(archive, category: .installers))
        expectFalse(p.allows(nested, category: .installers))
    }
    func testRecentNestedLogProtected() throws {
        try file("Library/Logs/test-app/recent.log")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-35 * 86400)], ofItemAtPath: root.appendingPathComponent("Library/Logs/test-app").path)
        let report = DiskScanner(home: root).scan()
        expectFalse(try require(report.items.first { $0.category == .logs }).eligible)
    }
    func testCancelledScanCannotValidatePartialMeasurement() throws {
        try file("Library/Caches/test-app/a")
        let flag = CancellationFlag(); flag.cancel()
        let scanner = DiskScanner(home: root, cancellation: flag)
        expectFalse(scanner.measure(root.appendingPathComponent("Library/Caches/test-app")).complete)
        expectTrue(scanner.scan().cancelled)
    }
    func testLimitMakesMeasurementIneligible() throws {
        try file("Library/Caches/test-app/a"); try file("Library/Caches/test-app/b")
        let measurement = DiskScanner(home: root).measure(root.appendingPathComponent("Library/Caches/test-app"), limit: 1)
        expectFalse(measurement.complete)
    }
    func testDuplicateSelectionsNeverReachTrash() throws {
        try file("Library/Caches/test-app/a")
        let candidate = item("Library/Caches/test-app")
        var calls = 0
        let entries = Cleaner(home: root).clean([candidate, candidate], trash: { url in calls += 1; return url })
        expectEqual(calls, 0); expectEqual(entries.filter(\.success).count, 0)
    }
    func testActiveApplicationNeverReachesTrash() throws {
        try file("Library/Caches/test-app/a")
        var calls = 0
        let entries = Cleaner(home: root).clean([item("Library/Caches/test-app")], blockingReason: { _ in "测试应用仍在运行" }, trash: { url in calls += 1; return url })
        expectEqual(calls, 0); expectFalse(try require(entries.first).success)
        expectEqual(entries.first?.message, "测试应用仍在运行")
    }
    func testTrashFailureReportedWithoutSuccess() throws {
        try file("Library/Caches/test-app/a")
        let entries = Cleaner(home: root).clean([item("Library/Caches/test-app")], trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        expectFalse(try require(entries.first).success)
        expectTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/Caches/test-app/a").path))
    }
    func testMoveAndAuditUsingIsolatedTrashAdapter() throws {
        try file("Library/Caches/test-app/a")
        let destination = root.appendingPathComponent("fixture-trash")
        var journal: [CleanupEntry] = []
        let entries = Cleaner(home: root).clean([item("Library/Caches/test-app")], onEntry: { journal.append($0) }, trash: { url in
            try FileManager.default.moveItem(at: url, to: destination); return destination
        })
        expectTrue(try require(entries.first).success)
        expectEqual(journal.count, 1)
        expectEqual(journal.first?.destination, destination.path)
        expectTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a").path))
    }
    func testLargeFileDiscoveryNeverCleanableOrFollowsLinks() throws {
        try file("Downloads/large.bin")
        let secret = try file("Documents/hidden.bin")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Downloads/alias.bin"), withDestinationURL: secret)
        let report = DiskScanner(home: root).largeFiles(roots: [root.appendingPathComponent("Downloads")], minimum: 1)
        expectEqual(report.items.count, 1)
        expectEqual(report.items.first?.title, "large.bin")
        expectFalse(try require(report.items.first).eligible)
    }
    func testScanDoesNotMutateFilesOrDoubleCountDeveloperCaches() throws {
        let url = try file("Library/Caches/go-build/a")
        let before = try Data(contentsOf: url)
        let report = DiskScanner(home: root).scan()
        expectEqual(report.items.filter { $0.path == url.deletingLastPathComponent().path }.count, 1)
        expectEqual(report.items.first?.category, .developer)
        expectEqual(try Data(contentsOf: url), before)
    }
    func testSystemTrashAndRestoreSyntheticFixture() throws {
        let path = "Library/Caches/qingfeng-fixture-\(UUID().uuidString)"
        let original = try file(path + "/synthetic.txt")
        let entries = Cleaner(home: root).clean([item(path)])
        let entry = try require(entries.first)
        expectTrue(entry.success)
        if !entry.success { throw NSError(domain: "TrashIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: entry.message]) }
        let moved = URL(fileURLWithPath: try require(entry.destination))
        defer { try? FileManager.default.moveItem(at: moved, to: original.deletingLastPathComponent()) }
        expectFalse(FileManager.default.fileExists(atPath: original.path))
        expectEqual(try String(contentsOf: moved.appendingPathComponent("synthetic.txt"), encoding: .utf8), "temporary synthetic fixture")
        try FileManager.default.moveItem(at: moved, to: original.deletingLastPathComponent())
        expectTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testScanErrorsDistinguishPermissionAndVanishedFiles() {
        for code in [Int(EPERM), Int(EACCES)] {
            expectEqual(ScanIssue.classify(NSError(domain: NSPOSIXErrorDomain, code: code)), .permission)
        }
        for code in [Int(ENOENT), Int(ENOTDIR)] {
            expectEqual(ScanIssue.classify(NSError(domain: NSPOSIXErrorDomain, code: code)), .changed)
        }
        expectEqual(ScanIssue.classify(CocoaError(.fileReadNoPermission)), .permission)
        expectEqual(ScanIssue.classify(CocoaError(.fileReadNoSuchFile)), .changed)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))])
        expectEqual(ScanIssue.classify(wrapped), .changed)
        expectEqual(ScanIssue.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))), .io)
    }

    func testMissingFileDuringMeasurementIsNotPermissionFailure() {
        let scanner = DiskScanner(home: root)
        let measurement = scanner.measure(root.appendingPathComponent("already-removed-cache"))
        expectFalse(measurement.complete)
        expectEqual(scanner.scanIssues.first?.category, .changed)
        var report = ScanReport(); report.issues = scanner.scanIssues
        expectFalse(report.hasPermissionIssues)
        expectTrue(report.issueSummary.contains("文件已变化"))
    }

    func testScanLimitOnlyReportedWhenEntriesRemain() throws {
        try file("Library/Caches/app/a")
        let url = root.appendingPathComponent("Library/Caches/app")
        let exact = DiskScanner(home: root)
        expectTrue(exact.measure(url, limit: 2).complete)
        expectTrue(exact.scanIssues.isEmpty)
        let partial = DiskScanner(home: root)
        expectFalse(partial.measure(url, limit: 1).complete)
        expectEqual(partial.scanIssues.first?.category, .limit)
        var report = ScanReport(); report.issues = partial.scanIssues
        expectFalse(report.hasPermissionIssues)
        expectTrue(report.issueSummary.contains("扫描上限"))
        let flag = CancellationFlag(); flag.cancel()
        let cancelled = DiskScanner(home: root, cancellation: flag)
        expectFalse(cancelled.measure(url, limit: 0).complete)
        expectTrue(cancelled.scanIssues.isEmpty)
    }

    func testLegacyReportsDoNotAssumePermissionFailure() throws {
        let data = Data(#"{"path":"/cache/item","message":"旧版诊断"}"#.utf8)
        let issue = try JSONDecoder().decode(ScanIssue.self, from: data)
        expectEqual(issue.category, .io)
        var report = ScanReport(); report.issues = [issue]
        expectFalse(report.hasPermissionIssues)
        report.issues.append(ScanIssue(path: "/denied", error: CocoaError(.fileReadNoPermission)))
        expectTrue(report.hasPermissionIssues)
        let decoded = try JSONDecoder().decode(ScanReport.self, from: JSONEncoder().encode(report))
        expectTrue(decoded.hasPermissionIssues)
    }

    func testGoLandDoesNotBlockOtherIDEProductsOrOlderVersions() {
        // Synthetic versions and process IDs, independent of any local app inventory.
        let apps = [RunningApplicationInfo(bundleID: "com.jetbrains.goland", name: "GoLand", version: "2099.1.0",
                                           processID: 4242, jetBrainsDirectory: "GoLand2099.1")]
        for directory in ["RustRover2099.1/tmp", "Aqua2099.1/tmp", "IntelliJIdea2099.1/compile-server", "GoLand2098.1/index"] {
            let path = root.appendingPathComponent("Library/Caches/JetBrains/" + directory).path
            expectTrue(ApplicationUsage.blockers(for: path, applications: apps).isEmpty)
        }
        let current = root.appendingPathComponent("Library/Caches/JetBrains/GoLand2099.1/index").path
        expectEqual(ApplicationUsage.blockers(for: current, applications: apps).count, 1)
        let reason = ApplicationUsage.blockingReason(for: current, applications: apps) ?? ""
        expectTrue(reason.contains("GoLand 2099.1.0")); expectTrue(reason.contains("4242"))
    }

    func testIDEFallbackProtectsOnlySameProductWhenVersionUnknown() {
        let app = RunningApplicationInfo(bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA")
        let base = root.appendingPathComponent("Library/Caches/JetBrains")
        expectEqual(ApplicationUsage.blockers(for: base.appendingPathComponent("IntelliJIdea2099.1/tmp").path, applications: [app]).count, 1)
        expectTrue(ApplicationUsage.blockers(for: base.appendingPathComponent("Aqua2099.1/tmp").path, applications: [app]).isEmpty)
        let toolbox = RunningApplicationInfo(bundleID: "com.jetbrains.toolbox", name: "JetBrains Toolbox")
        expectTrue(ApplicationUsage.blockers(for: base.appendingPathComponent("IntelliJIdea2099.1/tmp").path, applications: [toolbox]).isEmpty)
    }

    func testRunningBrainAndChromeStillProtectedWithActionableNames() {
        let apps = [RunningApplicationInfo(bundleID: "com.brain.app", name: "Brain", version: "1.0.0", processID: 101),
                    RunningApplicationInfo(bundleID: "com.google.Chrome", name: "Google Chrome", processID: 102)]
        let updater = root.appendingPathComponent("Library/Caches/brain-updater").path
        expectTrue((ApplicationUsage.blockingReason(for: updater, applications: apps) ?? "").contains("Brain 1.0.0"))
        let chrome = root.appendingPathComponent("Library/Caches/Google").path
        expectTrue((ApplicationUsage.blockingReason(for: chrome, applications: apps) ?? "").contains("Google Chrome"))
        expectTrue(ApplicationUsage.blockers(for: updater, applications: []).isEmpty)
    }

    func testUnrelatedIDEAllowsFixtureCleanupButActiveIDEIsBlocked() throws {
        let paths = ["Library/Caches/JetBrains/Aqua2099.1/tmp", "Library/Caches/JetBrains/GoLand2099.1/index"]
        for path in paths { try file(path + "/fixture") }
        let apps = [RunningApplicationInfo(bundleID: "com.jetbrains.goland", name: "GoLand", jetBrainsDirectory: "GoLand2099.1")]
        var moved: [String] = []
        let entries = Cleaner(home: root).clean(paths.map { item($0, category: .developer) }, blockingReason: {
            ApplicationUsage.blockingReason(for: $0.path, applications: apps)
        }, trash: { url in
            let destination = self.root.appendingPathComponent("fixture-trash")
            try FileManager.default.moveItem(at: url, to: destination)
            moved.append(url.path); return destination
        })
        expectEqual(moved.count, 1)
        expectTrue(entries[0].success); expectFalse(entries[1].success)
        expectTrue(entries[1].message.contains("GoLand"))
        expectTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(paths[1] + "/fixture").path))
    }

    func testDirectoryScanLimitIsConfigurableAndBounded() throws {
        expectTrue(ScanLimit.isValidDirectory(10_000))
        expectTrue(ScanLimit.isValidDirectory(400_000))
        expectTrue(ScanLimit.isValidDirectory(1_000_000))
        expectFalse(ScanLimit.isValidDirectory(9_999))
        expectFalse(ScanLimit.isValidDirectory(1_000_001))
        expectEqual(ScanLimit.normalizedDirectory(400_000), 400_000)
        expectEqual(ScanLimit.normalizedDirectory(1), ScanLimit.minimumDirectory)
        expectEqual(ScanLimit.normalizedDirectory(2_000_000), ScanLimit.maximumDirectory)
        expectEqual(DiskScanner(home: root, directoryLimit: 400_000).directoryLimit, 400_000)
        expectEqual(Cleaner(home: root, directoryLimit: 400_000).directoryLimit, 400_000)
        // Explicit small limits remain available to focused callers/tests; user settings stay bounded above.
        let fixture = try file("Library/Caches/app/a")
        expectTrue(FileManager.default.fileExists(atPath: fixture.path))
        let scanner = DiskScanner(home: root, directoryLimit: 400_000)
        expectTrue(scanner.measure(root.appendingPathComponent("Library/Caches/app"), limit: 2).complete)
    }
}
