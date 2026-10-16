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
    var writes = 0
    var beforeWrite: (() -> Void)?
    let initial = Data("original".utf8)
    let applied = Data("on".utf8)
    func read(_ feature: Feature) throws -> FeatureState {
        FeatureState(enabled: values[feature] == applied, detail: "Unavailable", available: !unavailable.contains(feature))
    }
    func snapshot(_ feature: Feature) throws -> Data { values[feature] ?? initial }
    func apply(_ feature: Feature, intensity: Double) throws {
        beforeWrite?()
        writes += 1
        values[feature] = applied // Simulate a partial mutation before an OS error.
        if failApply.contains(feature) { throw MonkError("Apply failed") }
    }
    func disable(_ feature: Feature) throws { beforeWrite?(); writes += 1; values[feature] = Data("off".utf8) }
    func restore(_ feature: Feature, from data: Data) throws {
        if failRestore.contains(feature) { throw MonkError("Display disconnected") }
        beforeWrite?()
        writes += 1
        values[feature] = data
    }
    func finishChanges() throws {}
}

@MainActor final class SettingsEngineTests {
    func testAllSnapshotsPersistBeforeFirstMutation() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.unavailable = [.stageManager]
        let engine = try SettingsEngine(backend: backend, store: store)
        backend.beforeWrite = { expectEqual(store.journal.monk.count, Feature.allCases.count - 1) }
        let issues = try engine.enableMonk(intensity: 0.5)
        expectEqual(issues.map(\.feature), [.stageManager])
        expectTrue(engine.hasMonkSession)
    }

    func testDiskFailurePreventsEveryMutation() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        store.failSave = true
        expectThrows(try engine.enableMonk(intensity: 0.5))
        expectThrows(try engine.set(.grayscale, enabled: true, intensity: 0.5))
        expectEqual(backend.writes, 0)
        expectFalse(engine.hasMonkSession)
    }

    func testRepeatedEnablePreservesOriginalSnapshot() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        _ = try engine.enableMonk(intensity: 0.5)
        _ = try engine.enableMonk(intensity: 0.8)
        expectEqual(store.journal.monk[Feature.grayscale.rawValue], backend.initial)
        expectTrue(engine.restoreMonk().isEmpty)
        expectEqual(backend.values[.grayscale], backend.initial)
        expectFalse(engine.hasMonkSession)
    }

    func testApplyFailureKeepsRecoverableOriginal() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.failApply = [.grayscale]
        let engine = try SettingsEngine(backend: backend, store: store)
        let issues = try engine.enableMonk(intensity: 0.5)
        expectTrue(issues.contains { $0.feature == .grayscale })
        expectEqual(store.journal.monk[Feature.grayscale.rawValue], backend.initial)
        expectTrue(engine.restoreMonk().isEmpty)
        expectEqual(backend.values[.grayscale], backend.initial)
    }

    func testRestoreFailureRetainsOnlyPendingRecordAcrossRestart() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        _ = try engine.enableMonk(intensity: 0.5)
        backend.failRestore = [.blackWallpaper]
        expectEqual(engine.restoreMonk().map(\.feature), [.blackWallpaper])
        expectEqual(Set(store.journal.monk.keys), [Feature.blackWallpaper.rawValue])
        let restarted = try SettingsEngine(backend: backend, store: store)
        expectTrue(restarted.hasMonkSession)
        backend.failRestore = []
        expectTrue(restarted.restoreMonk().isEmpty)
        expectFalse(restarted.hasMonkSession)
    }

    func testIndividualBaselineSurvivesMonkSession() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        try engine.set(.hideDock, enabled: true, intensity: 0.5)
        _ = try engine.enableMonk(intensity: 0.5)
        expectTrue(engine.restoreMonk().isEmpty)
        expectEqual(backend.values[.hideDock], backend.applied)
        expectTrue(engine.restoreIndividual().isEmpty)
        expectEqual(backend.values[.hideDock], backend.initial)
    }

    func testEditsDuringMonkDoNotCreateConflictingIndividualBaseline() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        _ = try engine.enableMonk(intensity: 0.5)
        try engine.set(.grayscale, enabled: true, intensity: 0.8)
        try engine.set(.hideDock, enabled: false, intensity: 0.5)
        expectTrue(store.journal.individual.isEmpty)
        expectTrue(engine.restoreMonk().isEmpty)
        expectEqual(backend.values[.grayscale], backend.initial)
        expectEqual(backend.values[.hideDock], backend.initial)
    }

    func testIndividualOffReallyDisablesAnOriginallyEnabledFeature() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.values[.grayscale] = backend.applied
        let engine = try SettingsEngine(backend: backend, store: store)
        try engine.set(.grayscale, enabled: true, intensity: 0.5)
        try engine.set(.grayscale, enabled: false, intensity: 0.5)
        expectEqual(try backend.read(.grayscale).enabled, false)
        expectTrue(engine.hasIndividualChanges)
        expectTrue(engine.restoreIndividual().isEmpty)
        expectEqual(backend.values[.grayscale], backend.applied)
    }

    func testFailedIndividualApplyIsRecoverable() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        backend.failApply = [.hideDock]
        expectThrows(try engine.set(.hideDock, enabled: true, intensity: 0.5))
        expectTrue(engine.hasIndividualChanges)
        expectTrue(engine.restoreIndividual().isEmpty)
        expectEqual(backend.values[.hideDock], backend.initial)
    }

    func testDisablingPreexistingFeatureSavesItsBaseline() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.values[.hideMenuBar] = backend.applied
        let engine = try SettingsEngine(backend: backend, store: store)
        try engine.set(.hideMenuBar, enabled: false, intensity: 0.5)
        expectEqual(try backend.read(.hideMenuBar).enabled, false)
        expectEqual(store.journal.individual[Feature.hideMenuBar.rawValue], backend.applied)
        expectTrue(engine.restoreIndividual().isEmpty)
        expectEqual(backend.values[.hideMenuBar], backend.applied)
    }

    func testSavingRestoreProgressFailureKeepsRetryableJournal() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        _ = try engine.enableMonk(intensity: 0.5)
        store.failSave = true
        expectFalse(engine.restoreMonk().isEmpty)
        expectTrue(engine.hasMonkSession)
        store.failSave = false
        expectTrue(engine.restoreMonk().isEmpty)
        expectFalse(engine.hasMonkSession)
    }

    func testFileStoreRoundTripAndCorruptFilePreservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRestoreStore(url: directory.appendingPathComponent("restore.json"))
        expectEqual(try store.load(), RestoreJournal())
        var journal = RestoreJournal()
        journal.monk[Feature.instantDock.rawValue] = Data([0, 1, 2, 255])
        try store.save(journal)
        expectEqual(try store.load(), journal)
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: store.url)
        expectThrows(try store.load())
        expectEqual(try Data(contentsOf: store.url), corrupt)
    }

    func testUnknownRestoreVersionIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRestoreStore(url: directory.appendingPathComponent("restore.json"))
        var journal = RestoreJournal()
        journal.version = 99
        try store.save(journal)
        expectThrows(try store.load())
    }
}
