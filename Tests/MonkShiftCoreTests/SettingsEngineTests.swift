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
        await beforeSnapshot?(feature)
        return values[feature] ?? initial
    }
    func apply(_ feature: Feature, intensity: Double) async throws {
        await beforeWrite?()
        writes += 1
        values[feature] = applied // Simulate a partial mutation before an OS error.
        if failApply.contains(feature) { throw MonkError("Apply failed") }
    }
    func disable(_ feature: Feature) async throws { await beforeWrite?(); writes += 1; values[feature] = Data("off".utf8) }
    func restore(_ feature: Feature, from data: Data) async throws {
        if failRestore.contains(feature) { throw MonkError("Display disconnected") }
        await beforeWrite?()
        writes += 1
        values[feature] = data
    }
    func finishChanges() throws { if failFinish { throw MonkError("Dock reload failed") } }
}

@MainActor final class SettingsEngineTests {
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
