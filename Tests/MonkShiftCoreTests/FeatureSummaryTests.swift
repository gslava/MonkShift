import MonkShiftCore

@MainActor final class FeatureSummaryTests {
    private func states(enabled: Bool) -> [Feature: FeatureState] {
        Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0, FeatureState(enabled: enabled)) })
    }

    func testAllEnabledRequiresEveryObservedSetting() async throws {
        let summary = FeatureSummary(states: states(enabled: true))
        expectEqual(summary.status, .allEnabled)
        expectEqual(summary.enabledCount, summary.totalCount)
        expectEqual(summary.unknownCount + summary.unavailableCount, 0)
    }

    func testAllOffRequiresEveryObservedSetting() async throws {
        expectEqual(FeatureSummary(states: states(enabled: false)).status, .off)
    }

    func testPartialReflectsIndividualSettings() async throws {
        var observed = states(enabled: false)
        observed[.hideDock] = FeatureState(enabled: true)
        let summary = FeatureSummary(states: observed)
        expectEqual(summary.status, .partiallyEnabled)
        expectEqual(summary.enabledCount, 1)
    }

    func testMissingAndUnknownSettingsPreventOffOrAllEnabled() async throws {
        expectEqual(FeatureSummary(states: [:]).status, .unknown)
        var observed = states(enabled: false)
        observed.removeValue(forKey: .grayscale)
        observed[.hideDock] = FeatureState(enabled: nil)
        let summary = FeatureSummary(states: observed)
        expectEqual(summary.status, .unknown)
        expectEqual(summary.unknownCount, 2)
        expectTrue(summary.detail.contains("2 unknown"))

        observed = states(enabled: true)
        observed.removeValue(forKey: .grayscale)
        expectEqual(FeatureSummary(states: observed).status, .partiallyEnabled)
    }

    func testUnavailableSettingNeverCountsAsConfirmedEnabled() async throws {
        var observed = states(enabled: true)
        observed[.stageManager] = FeatureState(enabled: true, available: false)
        let summary = FeatureSummary(states: observed)
        expectEqual(summary.status, .partiallyEnabled)
        expectEqual(summary.enabledCount, summary.totalCount - 1)
        expectEqual(summary.unavailableCount, 1)
        expectTrue(summary.detail.contains("1 unavailable"))

        observed = states(enabled: false)
        observed[.stageManager] = FeatureState(enabled: nil, available: false)
        expectEqual(FeatureSummary(states: observed).status, .unknown)
    }
}
