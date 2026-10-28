import Foundation

private var failures = 0
private func fail(_ message: String, file: StaticString, line: UInt) {
    failures += 1
    print("FAIL \(file):\(line): \(message)")
}
func expectTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { fail("Expected true", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
func expectFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { fail("Expected false", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
func expectEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try a() != b() { fail("Values differ", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
func expectNoThrow(_ action: @autoclosure () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    do { try action() } catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
func expectThrows(_ action: @autoclosure () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    do { try action(); fail("Expected rejection", file: file, line: line) } catch {}
}
func require<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "CoreChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected a value"]) }
    return value
}

@main enum CoreChecks {
    static func main() {
        let suite = CleanerTests()
        let tests: [(String, () throws -> Void)] = [
            ("testUnchangedCacheValidates", suite.testUnchangedCacheValidates),
            ("testChangedNestedFileRejectedEvenSameLength", suite.testChangedNestedFileRejectedEvenSameLength),
            ("testAddedFileRejected", suite.testAddedFileRejected),
            ("testDeletedNestedFileRejected", suite.testDeletedNestedFileRejected),
            ("testSymlinkTargetAndAncestorRejected", suite.testSymlinkTargetAndAncestorRejected),
            ("testNestedSymlinkPreventsCleanupAndIsNotTraversed", suite.testNestedSymlinkPreventsCleanupAndIsNotTraversed),
            ("testPathPrefixCannotEscapeHome", suite.testPathPrefixCannotEscapeHome),
            ("testCacheRootAndArbitraryDocumentsProtected", suite.testCacheRootAndArbitraryDocumentsProtected),
            ("testJetBrainsHistoryAndAppleCachesProtected", suite.testJetBrainsHistoryAndAppleCachesProtected),
            ("testModelsAndContainersNeverCleanable", suite.testModelsAndContainersNeverCleanable),
            ("testInstallerNeedsAgeExtensionAndDownloadsRoot", suite.testInstallerNeedsAgeExtensionAndDownloadsRoot),
            ("testRecentNestedLogProtected", suite.testRecentNestedLogProtected),
            ("testCancelledScanCannotValidatePartialMeasurement", suite.testCancelledScanCannotValidatePartialMeasurement),
            ("testLimitMakesMeasurementIneligible", suite.testLimitMakesMeasurementIneligible),
            ("testDuplicateSelectionsNeverReachTrash", suite.testDuplicateSelectionsNeverReachTrash),
            ("testActiveApplicationNeverReachesTrash", suite.testActiveApplicationNeverReachesTrash),
            ("testTrashFailureReportedWithoutSuccess", suite.testTrashFailureReportedWithoutSuccess),
            ("testMoveAndAuditUsingIsolatedTrashAdapter", suite.testMoveAndAuditUsingIsolatedTrashAdapter),
            ("testLargeFileDiscoveryNeverCleanableOrFollowsLinks", suite.testLargeFileDiscoveryNeverCleanableOrFollowsLinks),
            ("testScanDoesNotMutateFilesOrDoubleCountDeveloperCaches", suite.testScanDoesNotMutateFilesOrDoubleCountDeveloperCaches),
            ("testSystemTrashAndRestoreSyntheticFixture", suite.testSystemTrashAndRestoreSyntheticFixture),
            ("testScanErrorsDistinguishPermissionAndVanishedFiles", suite.testScanErrorsDistinguishPermissionAndVanishedFiles),
            ("testMissingFileDuringMeasurementIsNotPermissionFailure", suite.testMissingFileDuringMeasurementIsNotPermissionFailure),
            ("testScanLimitOnlyReportedWhenEntriesRemain", suite.testScanLimitOnlyReportedWhenEntriesRemain),
            ("testLegacyReportsDoNotAssumePermissionFailure", suite.testLegacyReportsDoNotAssumePermissionFailure),
            ("testGoLandDoesNotBlockOtherIDEProductsOrOlderVersions", suite.testGoLandDoesNotBlockOtherIDEProductsOrOlderVersions),
            ("testIDEFallbackProtectsOnlySameProductWhenVersionUnknown", suite.testIDEFallbackProtectsOnlySameProductWhenVersionUnknown),
            ("testRunningBrainAndChromeStillProtectedWithActionableNames", suite.testRunningBrainAndChromeStillProtectedWithActionableNames),
            ("testUnrelatedIDEAllowsFixtureCleanupButActiveIDEIsBlocked", suite.testUnrelatedIDEAllowsFixtureCleanupButActiveIDEIsBlocked),
            ("testDirectoryScanLimitIsConfigurableAndBounded", suite.testDirectoryScanLimitIsConfigurableAndBounded)
        ]
        var passed = 0
        for (name, test) in tests {
            let before = failures
            do { try suite.setUpWithError(); try test() }
            catch { fail("\(name): \(error)", file: #filePath, line: #line) }
            do { try suite.tearDownWithError() }
            catch { fail("Fixture cleanup: \(error)", file: #filePath, line: #line) }
            if failures == before { passed += 1; print("PASS \(name)") }
        }
        print("Core checks: \(passed)/\(tests.count) passed, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
