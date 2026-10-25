import Foundation

@MainActor private enum CheckResults {
    static var failures: [String] = []
    static func fail(_ message: String, file: String, line: UInt) {
        failures.append("\(file):\(line): \(message)")
    }
}

@MainActor func expectEqual<T: Equatable>(_ lhs: @autoclosure () async throws -> T, _ rhs: @autoclosure () async throws -> T,
    file: String = #filePath, line: UInt = #line) async {
    do {
        let left = try await lhs(), right = try await rhs()
        if left != right { CheckResults.fail("Expected \(right), got \(left)", file: file, line: line) }
    } catch { CheckResults.fail("Unexpected error: \(error)", file: file, line: line) }
}

@MainActor func expectTrue(_ value: @autoclosure () async throws -> Bool, file: String = #filePath, line: UInt = #line) async {
    await expectEqual(try await value(), true, file: file, line: line)
}
@MainActor func expectFalse(_ value: @autoclosure () async throws -> Bool, file: String = #filePath, line: UInt = #line) async {
    await expectEqual(try await value(), false, file: file, line: line)
}
@MainActor func expectThrows<T>(_ operation: @autoclosure () async throws -> T, file: String = #filePath, line: UInt = #line) async {
    do { _ = try await operation(); CheckResults.fail("Expected an error", file: file, line: line) }
    catch { /* Expected. */ }
}

@main enum CheckRunner {
    @MainActor static func main() async {
        let suite = SettingsEngineTests()
        let summary = FeatureSummaryTests()
        let profiles = ProfileTests()
        let focusExit = FocusExitTests()
        let tests: [(String, () async throws -> Void)] = [
            ("Exiting focus stops pre-existing Stage Manager and preserves Restore All", focusExit.testExitStopsPreexistingStageManagerAndRestoreAllRecoversIt),
            ("Exiting an external focus mode saves Stage Manager before mutation", focusExit.testExitOfExternallyEnabledModeSavesStageBeforeStoppingIt),
            ("Failed focus shutdown remains retryable after restart", focusExit.testFailedShutdownRemainsRetryableAcrossRestart),
            ("Ignored Stage Manager shutdown is reported and remains recoverable", focusExit.testIgnoredShutdownDoesNotReportSuccessOrLoseBaseline),
            ("Dimming cannot stop Stage Manager without a durable snapshot", focusExit.testDimmingDoesNotStopStageWithoutItsSnapshot),
            ("Profiles copy settings and survive restart with validated names", profiles.testLibraryRoundTripAndNames),
            ("Invalid profiles preserve the existing file", profiles.testInvalidLibrariesPreserveFiles),
            ("Profile switches save all baselines before the first mutation", profiles.testSwitchesSaveEveryBaselineBeforeMutation),
            ("Profile snapshot and disk failures prevent mutations", profiles.testSnapshotAndDiskFailureBlockProfileMutation),
            ("Failed profile application restores after restart", profiles.testProfileFailuresRemainRecoverableAfterRestart),
            ("Profile switches preserve a surrounding Monk baseline", profiles.testProfileWithinMonkPreservesSessionBaseline),
            ("Profile operations reject interleaved changes", profiles.testProfileOperationsRejectInterleaving),
            ("Focus exit stops Stage Manager and restores recent-app visibility", suite.testOneWindowStopsStageAndRestoresRecentAppsForEachCycle),
            ("Recent apps prerequisite failures preserve the other mode", suite.testRecentAppsPrerequisiteFailuresPreserveOtherMode),
            ("Recent apps restoration survives restart and retries", suite.testRecentAppsRestoreFailureSurvivesRestart),
            ("Monk sessions preserve the recent apps focus baseline", suite.testMonkPreservesRecentAppsFocusBaseline),
            ("Monk recent apps failures preserve the other mode", suite.testMonkRecentAppsFailuresPreserveOtherMode),
            ("Focus exit stops Stage Manager while Restore All preserves the first baseline", suite.testOneWindowStopsStageManagerAndPreservesBaseline),
            ("Switching to dimming stops Stage Manager first", suite.testDimmingSwitchStopsStageManager),
            ("Stage Manager prerequisite failures preserve the other mode", suite.testStageManagerPrerequisiteFailuresPreserveOtherMode),
            ("Stage Manager shutdown failure survives restart and retries", suite.testStageManagerShutdownRetryAfterRestart),
            ("Failed focus metadata writes remain retryable", suite.testStageManagerCycleClearFailureIsRetryable),
            ("Monk restoration preserves the earlier individual focus cycle", suite.testMonkPreservesEarlierFocusCycle),
            ("Focus exit within Monk stops Stage Manager and preserves session restoration", suite.testFocusExitWithinMonkStopsStageAndRetainsSession),
            ("Monk Stage Manager failures do not switch focus modes", suite.testMonkStageManagerFailurePreservesOtherMode),
            ("Existing journals decode without focus metadata", suite.testLegacyJournalDecodesWithoutFocusMetadata),
            ("Failed session metadata cleanup survives restart", suite.testMonkFocusCleanupFailureRetainsSession),
            ("Focus switches persist both baselines before mutations", suite.testFocusModesSaveBothBaselinesBeforeSwitching),
            ("Focus snapshot and disable failures prevent the other mode", suite.testFocusSnapshotOrDisableFailurePreventsOtherModeEnabling),
            ("Monk Mode applies only the selected focus mode and its intensity", suite.testMonkUsesSelectedModeAndIndependentIntensity),
            ("Unselected dimming permission does not block Monk Mode", suite.testUnselectedDimmingPermissionDoesNotBlockMonkMode),
            ("Unavailable selected focus mode leaves the existing mode alone", suite.testSelectedUnavailableModeDoesNotDisableExistingMode),
            ("Legacy journals restore without touching background dimming", suite.testLegacyJournalWithoutDimmingRestoresAfterRestart),
            ("Focus restoration failures survive a file-store restart", suite.testFocusRestoreFailureSurvivesFileStoreRestart),
            ("Status counts only the selected focus mode", summary.testSummaryIncludesOnlyTheSelectedFocusMode),
            ("Snapshots saved before mutation", suite.testAllSnapshotsPersistBeforeFirstMutation),
            ("Disk failure blocks mutation", suite.testDiskFailurePreventsEveryMutation),
            ("Repeated enable keeps original", suite.testRepeatedEnablePreservesOriginalSnapshot),
            ("Failed apply remains recoverable", suite.testApplyFailureKeepsRecoverableOriginal),
            ("Partial restore survives restart", suite.testRestoreFailureRetainsOnlyPendingRecordAcrossRestart),
            ("Individual baseline survives session", suite.testIndividualBaselineSurvivesMonkSession),
            ("Session edits preserve baseline", suite.testEditsDuringMonkDoNotCreateConflictingIndividualBaseline),
            ("Individual off disables original on state", suite.testIndividualOffReallyDisablesAnOriginallyEnabledFeature),
            ("Individual apply failure recovery", suite.testFailedIndividualApplyIsRecoverable),
            ("Disabling pre-existing feature saves baseline", suite.testDisablingPreexistingFeatureSavesItsBaseline),
            ("Restore progress persistence failure", suite.testSavingRestoreProgressFailureKeepsRetryableJournal),
            ("File round trip and corruption", suite.testFileStoreRoundTripAndCorruptFilePreservation),
            ("Unknown restore version rejected", suite.testUnknownRestoreVersionIsRejected),
            ("Concurrent changes blocked during snapshot", suite.testConcurrentMutationIsRejectedWhileSnapshotSuspends),
            ("Finalization failure retains restore records", suite.testFinalizationFailureKeepsRestoreRecords),
            ("Reduce Motion session restores either original state", suite.testReduceMotionSessionRestoresBothOriginalStates),
            ("Reduce Motion restore failure survives file-store restart", suite.testReduceMotionRestoreFailureSurvivesFileStoreRestart),
            ("Legacy sessions leave Reduce Motion untouched", suite.testLegacySessionLeavesReduceMotionUntouched),
            ("Legacy sessions leave desktop visibility untouched", suite.testLegacySessionLeavesDesktopVisibilityUntouched),
            ("All enabled requires observed settings", summary.testAllEnabledRequiresEveryObservedSetting),
            ("Off requires observed settings", summary.testAllOffRequiresEveryObservedSetting),
            ("Partial status reflects individual settings", summary.testPartialReflectsIndividualSettings),
            ("Unknown states prevent false status", summary.testMissingAndUnknownSettingsPreventOffOrAllEnabled),
            ("Unavailable states prevent false success", summary.testUnavailableSettingNeverCountsAsConfirmedEnabled)
        ]
        for (name, test) in tests {
            let before = CheckResults.failures.count
            do { try await test() }
            catch { CheckResults.failures.append("\(name): \(error)") }
            print("\(before == CheckResults.failures.count ? "PASS" : "FAIL") \(name)")
        }
        for failure in CheckResults.failures { print(failure) }
        print("\(tests.count) tests, \(CheckResults.failures.count) failures. No macOS settings changed.")
        if !CheckResults.failures.isEmpty { exit(1) }
    }
}
