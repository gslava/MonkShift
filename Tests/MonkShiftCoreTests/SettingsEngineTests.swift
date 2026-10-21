import Foundation
import MonkShiftCore

@MainActor final class MemoryStore: RestoreStore {
    var journal = RestoreJournal()
    var failSave = false
    func load() throws -> RestoreJournal { journal }
    func save(_ journal: RestoreJournal) throws {
        if failSave { throw MonkError("Disk full") }
        self.journal = journal
    }
}

@MainActor final class FakeBackend: SettingsBackend {
    var values: [Feature: Data] = [:]
    var unavailable: Set<Feature> = []
    var failApply: Set<Feature> = []
    var failRestore: Set<Feature> = []
    var failSnapshot: Set<Feature> = []
    var failDisable: Set<Feature> = []
    var intensities: [Feature: Double] = [:]
    var failFinish = false
    var writes = 0
    var beforeWrite: (() async -> Void)?
    var beforeSnapshot: ((Feature) async -> Void)?
    let initial = Data("original".utf8)
    let applied = Data("on".utf8)
    func read(_ feature: Feature) throws -> FeatureState {
        FeatureState(enabled: values[feature] == applied, detail: "Unavailable", available: !unavailable.contains(feature))
    }
    func snapshot(_ feature: Feature) async throws -> Data {
        if failSnapshot.contains(feature) { throw MonkError("Snapshot failed") }
        await beforeSnapshot?(feature)
        return values[feature] ?? initial
    }
    func apply(_ feature: Feature, intensity: Double) async throws {
        await beforeWrite?()
        writes += 1
        values[feature] = applied // Simulate a partial mutation before an OS error.
        intensities[feature] = intensity
        if failApply.contains(feature) { throw MonkError("Apply failed") }
    }
    func disable(_ feature: Feature) async throws {
        if failDisable.contains(feature) { throw MonkError("Disable failed") }
        await beforeWrite?(); writes += 1; values[feature] = Data("off".utf8)
    }
    func restore(_ feature: Feature, from data: Data) async throws {
        if failRestore.contains(feature) { throw MonkError("Display disconnected") }
        await beforeWrite?()
        writes += 1
        values[feature] = data
    }
    func finishChanges() throws { if failFinish { throw MonkError("Dock reload failed") } }
}

@MainActor final class SettingsEngineTests {
    func testFocusModesSaveBothBaselinesBeforeSwitching() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.values[.oneWindowAtATime] = backend.applied
        let engine = try SettingsEngine(backend: backend, store: store)
        backend.beforeWrite = {
            await expectEqual(store.journal.individual[Feature.oneWindowAtATime.rawValue], backend.applied)
            await expectEqual(store.journal.individual[Feature.dimBackground.rawValue], backend.initial)
        }
        try await engine.set(.dimBackground, enabled: true, intensity: 0.7)
        await expectEqual(try backend.read(.oneWindowAtATime).enabled, false)
        await expectEqual(try backend.read(.dimBackground).enabled, true)
        try await engine.set(.oneWindowAtATime, enabled: true, intensity: 0.5)
        await expectEqual(try backend.read(.dimBackground).enabled, false)
        backend.beforeWrite = nil
        await expectTrue(try await engine.restoreIndividual().isEmpty)
        await expectEqual(backend.values[.oneWindowAtATime], backend.applied)
        await expectEqual(backend.values[.dimBackground], backend.initial)
    }

    func testFocusSnapshotOrDisableFailurePreventsOtherModeEnabling() async throws {
        for failSnapshot in [true, false] {
            let backend = FakeBackend(), store = MemoryStore()
            let engine = try SettingsEngine(backend: backend, store: store)
            if failSnapshot { backend.failSnapshot = [.oneWindowAtATime] }
            else { backend.failDisable = [.oneWindowAtATime] }
            await expectThrows(try await engine.set(.dimBackground, enabled: true, intensity: 0.6))
            await expectEqual(backend.writes, 0)
            await expectEqual(try backend.read(.dimBackground).enabled, false)
        }
    }

    func testMonkUsesSelectedModeAndIndependentIntensity() async throws {
        for mode in [Feature.oneWindowAtATime, .dimBackground] {
            let backend = FakeBackend(), store = MemoryStore()
            let engine = try SettingsEngine(backend: backend, store: store)
            await expectTrue(try await engine.enableMonk(intensity: 0.2, focusMode: mode, dimmingIntensity: 0.8).isEmpty)
            await expectEqual(try backend.read(mode).enabled, true)
            await expectEqual(try backend.read(mode.alternativeFocusMode!).enabled, false)
            await expectEqual(backend.intensities[.grayscale], 0.2)
            if mode == .dimBackground { await expectEqual(backend.intensities[.dimBackground], 0.8) }
            _ = try await engine.enableMonk(intensity: 0.3, focusMode: mode.alternativeFocusMode!, dimmingIntensity: 0.7)
            await expectEqual(store.journal.monk[mode.rawValue], backend.initial)
            await expectTrue(try await engine.restoreMonk().isEmpty)
            await expectEqual(backend.values[mode], backend.initial)
        }
    }

    func testUnselectedDimmingPermissionDoesNotBlockMonkMode() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.unavailable = [.dimBackground]
        let engine = try SettingsEngine(backend: backend, store: store)
        await expectTrue(try await engine.enableMonk(intensity: 0.5).isEmpty)
        await expectEqual(try backend.read(.oneWindowAtATime).enabled, true)
        await expectEqual(try backend.read(.dimBackground).enabled, false)
        await expectTrue(try await engine.restoreMonk().isEmpty)
    }

    func testSelectedUnavailableModeDoesNotDisableExistingMode() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.values[.oneWindowAtATime] = backend.applied
        backend.unavailable = [.dimBackground]
        let engine = try SettingsEngine(backend: backend, store: store)
        let issues = try await engine.enableMonk(intensity: 0.5, focusMode: .dimBackground)
        await expectEqual(issues.map(\.feature), [.dimBackground])
        await expectEqual(backend.values[.oneWindowAtATime], backend.applied)
        await expectEqual(try backend.read(.hideDock).enabled, true)
    }

    func testLegacyJournalWithoutDimmingRestoresAfterRestart() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        store.journal.monk[Feature.oneWindowAtATime.rawValue] = backend.initial
        backend.values[.oneWindowAtATime] = backend.applied
        let engine = try SettingsEngine(backend: backend, store: store)
        await expectTrue(try await engine.restoreMonk().isEmpty)
        await expectEqual(backend.values[.dimBackground], nil)
    }

    func testFocusRestoreFailureSurvivesFileStoreRestart() async throws {
        for originalMode in [Feature.oneWindowAtATime, .dimBackground] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FocusRestore-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("restore.json")
            let backend = FakeBackend()
            backend.values[originalMode] = backend.applied
            let engine = try SettingsEngine(backend: backend, store: FileRestoreStore(url: url))
            try await engine.set(originalMode.alternativeFocusMode!, enabled: true, intensity: 0.8)
            backend.failRestore = [originalMode]
            await expectEqual(try await engine.restoreIndividual().map(\.feature), [originalMode])
            let restarted = try SettingsEngine(backend: backend, store: FileRestoreStore(url: url))
            await expectEqual(Set(restarted.journal.individual.keys), [originalMode.rawValue])
            backend.failRestore = []
            await expectTrue(try await restarted.restoreIndividual().isEmpty)
            await expectEqual(backend.values[originalMode], backend.applied)
            await expectEqual(try backend.read(originalMode.alternativeFocusMode!).enabled, false)
        }
    }

    func testReduceMotionSessionRestoresBothOriginalStates() async throws {
        for originallyEnabled in [false, true] {
            let backend = FakeBackend(), store = MemoryStore()
            let original = originallyEnabled ? backend.applied : backend.initial
            backend.values[.reduceMotion] = original
            let engine = try SettingsEngine(backend: backend, store: store)
            _ = try await engine.enableMonk(intensity: 0.5)
            await expectEqual(store.journal.monk[Feature.reduceMotion.rawValue], original)
            await expectTrue(try backend.read(.reduceMotion).enabled == true)
            _ = try await engine.restoreMonk()
            await expectEqual(backend.values[.reduceMotion], original)
            await expectFalse(engine.hasMonkSession)
        }
    }

    func testReduceMotionRestoreFailureSurvivesFileStoreRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReduceMotionChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = FakeBackend()
        let url = directory.appendingPathComponent("restore.json")
        let engine = try SettingsEngine(backend: backend, store: FileRestoreStore(url: url))
        _ = try await engine.enableMonk(intensity: 0.5)
        backend.failRestore = [.reduceMotion]
        await expectEqual(try await engine.restoreMonk().map(\.feature), [.reduceMotion])
        let restarted = try SettingsEngine(backend: backend, store: FileRestoreStore(url: url))
        await expectEqual(Set(restarted.journal.monk.keys), [Feature.reduceMotion.rawValue])
        backend.failRestore = []
        await expectTrue(try await restarted.restoreMonk().isEmpty)
        await expectEqual(backend.values[.reduceMotion], backend.initial)
        await expectFalse(restarted.hasMonkSession)
    }

    func testLegacySessionLeavesReduceMotionUntouched() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.values[.reduceMotion] = backend.applied
        for feature in Feature.allCases where feature != .reduceMotion {
            store.journal.monk[feature.rawValue] = backend.initial
            backend.values[feature] = backend.applied
        }
        let engine = try SettingsEngine(backend: backend, store: store)
        await expectTrue(try await engine.restoreMonk().isEmpty)
        await expectEqual(backend.values[.reduceMotion], backend.applied)
        await expectEqual(backend.writes, Feature.allCases.count - 1)
        await expectFalse(engine.hasMonkSession)
    }

    func testLegacySessionLeavesDesktopVisibilityUntouched() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.values[.hideDesktopItems] = backend.applied
        for feature in Feature.allCases where feature != .hideDesktopItems {
            store.journal.monk[feature.rawValue] = backend.initial
            backend.values[feature] = backend.applied
        }
        let engine = try SettingsEngine(backend: backend, store: store)
        await expectTrue(try await engine.restoreMonk().isEmpty)
        await expectEqual(backend.values[.hideDesktopItems], backend.applied)
        await expectEqual(backend.writes, Feature.allCases.count - 1)
        await expectFalse(engine.hasMonkSession)
    }

    func testAllSnapshotsPersistBeforeFirstMutation() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.unavailable = [.stageManager]
        let engine = try SettingsEngine(backend: backend, store: store)
        backend.beforeWrite = { await expectEqual(store.journal.monk.count, Feature.allCases.count - 1) }
        let issues = try await engine.enableMonk(intensity: 0.5)
        await expectEqual(issues.map(\.feature), [.stageManager])
        await expectTrue(engine.hasMonkSession)
    }

    func testDiskFailurePreventsEveryMutation() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        store.failSave = true
        await expectThrows(try await engine.enableMonk(intensity: 0.5))
        await expectThrows(try await engine.set(.grayscale, enabled: true, intensity: 0.5))
        await expectEqual(backend.writes, 0)
        await expectFalse(engine.hasMonkSession)
    }

    func testRepeatedEnablePreservesOriginalSnapshot() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        _ = try await engine.enableMonk(intensity: 0.5)
        _ = try await engine.enableMonk(intensity: 0.8)
        await expectEqual(store.journal.monk[Feature.grayscale.rawValue], backend.initial)
        await expectTrue(try await engine.restoreMonk().isEmpty)
        await expectEqual(backend.values[.grayscale], backend.initial)
        await expectFalse(engine.hasMonkSession)
    }

    func testApplyFailureKeepsRecoverableOriginal() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.failApply = [.grayscale]
        let engine = try SettingsEngine(backend: backend, store: store)
        let issues = try await engine.enableMonk(intensity: 0.5)
        await expectTrue(issues.contains { $0.feature == .grayscale })
        await expectEqual(store.journal.monk[Feature.grayscale.rawValue], backend.initial)
        await expectTrue(try await engine.restoreMonk().isEmpty)
        await expectEqual(backend.values[.grayscale], backend.initial)
    }

    func testRestoreFailureRetainsOnlyPendingRecordAcrossRestart() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        _ = try await engine.enableMonk(intensity: 0.5)
        backend.failRestore = [.blackWallpaper]
        await expectEqual(try await engine.restoreMonk().map(\.feature), [.blackWallpaper])
        await expectEqual(Set(store.journal.monk.keys), [Feature.blackWallpaper.rawValue])
        let restarted = try SettingsEngine(backend: backend, store: store)
        await expectTrue(restarted.hasMonkSession)
        backend.failRestore = []
        await expectTrue(try await restarted.restoreMonk().isEmpty)
        await expectFalse(restarted.hasMonkSession)
    }

    func testIndividualBaselineSurvivesMonkSession() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        try await engine.set(.hideDock, enabled: true, intensity: 0.5)
        _ = try await engine.enableMonk(intensity: 0.5)
        await expectTrue(try await engine.restoreMonk().isEmpty)
        await expectEqual(backend.values[.hideDock], backend.applied)
        await expectTrue(try await engine.restoreIndividual().isEmpty)
        await expectEqual(backend.values[.hideDock], backend.initial)
    }

    func testEditsDuringMonkDoNotCreateConflictingIndividualBaseline() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        _ = try await engine.enableMonk(intensity: 0.5)
        try await engine.set(.grayscale, enabled: true, intensity: 0.8)
        try await engine.set(.hideDock, enabled: false, intensity: 0.5)
        await expectTrue(store.journal.individual.isEmpty)
        await expectTrue(try await engine.restoreMonk().isEmpty)
        await expectEqual(backend.values[.grayscale], backend.initial)
        await expectEqual(backend.values[.hideDock], backend.initial)
    }

    func testIndividualOffReallyDisablesAnOriginallyEnabledFeature() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.values[.grayscale] = backend.applied
        let engine = try SettingsEngine(backend: backend, store: store)
        try await engine.set(.grayscale, enabled: true, intensity: 0.5)
        try await engine.set(.grayscale, enabled: false, intensity: 0.5)
        await expectEqual(try backend.read(.grayscale).enabled, false)
        await expectTrue(engine.hasIndividualChanges)
        await expectTrue(try await engine.restoreIndividual().isEmpty)
        await expectEqual(backend.values[.grayscale], backend.applied)
    }

    func testFailedIndividualApplyIsRecoverable() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        backend.failApply = [.hideDock]
        await expectThrows(try await engine.set(.hideDock, enabled: true, intensity: 0.5))
        await expectTrue(engine.hasIndividualChanges)
        await expectTrue(try await engine.restoreIndividual().isEmpty)
        await expectEqual(backend.values[.hideDock], backend.initial)
    }

    func testDisablingPreexistingFeatureSavesItsBaseline() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.values[.hideMenuBar] = backend.applied
        let engine = try SettingsEngine(backend: backend, store: store)
        try await engine.set(.hideMenuBar, enabled: false, intensity: 0.5)
        await expectEqual(try backend.read(.hideMenuBar).enabled, false)
        await expectEqual(store.journal.individual[Feature.hideMenuBar.rawValue], backend.applied)
        await expectTrue(try await engine.restoreIndividual().isEmpty)
        await expectEqual(backend.values[.hideMenuBar], backend.applied)
    }

    func testSavingRestoreProgressFailureKeepsRetryableJournal() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        _ = try await engine.enableMonk(intensity: 0.5)
        store.failSave = true
        await expectFalse(try await engine.restoreMonk().isEmpty)
        await expectTrue(engine.hasMonkSession)
        store.failSave = false
        await expectTrue(try await engine.restoreMonk().isEmpty)
        await expectFalse(engine.hasMonkSession)
    }

    func testFileStoreRoundTripAndCorruptFilePreservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRestoreStore(url: directory.appendingPathComponent("restore.json"))
        await expectEqual(try store.load(), RestoreJournal())
        var journal = RestoreJournal()
        journal.monk[Feature.instantDock.rawValue] = Data([0, 1, 2, 255])
        try store.save(journal)
        await expectEqual(try store.load(), journal)
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: store.url)
        await expectThrows(try store.load())
        await expectEqual(try Data(contentsOf: store.url), corrupt)
    }

    func testUnknownRestoreVersionIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRestoreStore(url: directory.appendingPathComponent("restore.json"))
        var journal = RestoreJournal()
        journal.version = 99
        try store.save(journal)
        await expectThrows(try store.load())
    }

    func testConcurrentMutationIsRejectedWhileSnapshotSuspends() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        let entered = AsyncStream<Void>.makeStream()
        var resumeSnapshot: CheckedContinuation<Void, Never>?
        backend.beforeSnapshot = { _ in
            await withCheckedContinuation { continuation in
                resumeSnapshot = continuation
                entered.continuation.yield(())
            }
        }
        let first = Task { try await engine.set(.hideDock, enabled: true, intensity: 0.5) }
        for await _ in entered.stream { break }
        await expectThrows(try await engine.set(.grayscale, enabled: true, intensity: 0.5))
        await expectEqual(backend.writes, 0)
        resumeSnapshot?.resume()
        try await first.value
        await expectEqual(backend.values[.hideDock], backend.applied)
        await expectEqual(backend.values[.grayscale], nil)
        await expectEqual(store.journal.individual[Feature.hideDock.rawValue], backend.initial)
        entered.continuation.finish()
    }

    func testFinalizationFailureKeepsRestoreRecords() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        _ = try await engine.enableMonk(intensity: 0.5)
        backend.failFinish = true
        let issues = try await engine.restoreMonk()
        await expectEqual(issues.count, Feature.allCases.count)
        await expectEqual(store.journal.monk.count, Feature.allCases.count)
        let restarted = try SettingsEngine(backend: backend, store: store)
        backend.failFinish = false
        await expectTrue(try await restarted.restoreMonk().isEmpty)
        await expectFalse(restarted.hasMonkSession)
    }
}
