import Foundation
import MonkShiftCore

@MainActor final class FocusExitTests {
    func testExitStopsPreexistingStageManagerAndRestoreAllRecoversIt() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.values[.stageManager] = backend.applied
        backend.values[.hideRecentApps] = backend.applied
        let engine = try SettingsEngine(backend: backend, store: store)
        try await engine.set(.oneWindowAtATime, enabled: true, intensity: 0.5)
        let baseline = store.journal.individual
        try await engine.set(.oneWindowAtATime, enabled: false, intensity: 0.5)
        await expectFalse(try backend.read(.stageManager).enabled == true)
        await expectFalse(try backend.read(.oneWindowAtATime).enabled == true)
        await expectEqual(store.journal.individual, baseline)
        await expectTrue(try await engine.restoreIndividual().isEmpty)
        await expectEqual(backend.values[.stageManager], backend.applied)
    }

    func testExitOfExternallyEnabledModeSavesStageBeforeStoppingIt() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.values[.stageManager] = backend.applied
        backend.values[.oneWindowAtATime] = backend.applied
        let engine = try SettingsEngine(backend: backend, store: store)
        backend.beforeWrite = {
            await expectEqual(store.journal.individual["stageManager"], backend.applied)
        }
        try await engine.set(.oneWindowAtATime, enabled: false, intensity: 0.5)
        backend.beforeWrite = nil
        await expectFalse(try backend.read(.stageManager).enabled == true)
        await expectTrue(try await engine.restoreIndividual().isEmpty)
        await expectEqual(backend.values[.stageManager], backend.applied)
        await expectEqual(backend.values[.oneWindowAtATime], backend.applied)
    }

    func testFailedShutdownRemainsRetryableAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FocusExit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("restore.json")
        let backend = FakeBackend()
        backend.values[.stageManager] = backend.applied
        let engine = try SettingsEngine(backend: backend, store: FileRestoreStore(url: url))
        try await engine.set(.oneWindowAtATime, enabled: true, intensity: 0.5)
        backend.failDisable = [.stageManager]
        await expectThrows(try await engine.set(.oneWindowAtATime, enabled: false, intensity: 0.5))
        let restarted = try SettingsEngine(backend: backend, store: FileRestoreStore(url: url))
        await expectEqual(restarted.journal.stageManagerBeforeOneWindow, backend.applied)
        backend.failDisable = []
        try await restarted.set(.oneWindowAtATime, enabled: false, intensity: 0.5)
        await expectFalse(try backend.read(.stageManager).enabled == true)
        await expectTrue(try await restarted.restoreIndividual().isEmpty)
        await expectEqual(backend.values[.stageManager], backend.applied)
    }

    func testIgnoredShutdownDoesNotReportSuccessOrLoseBaseline() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.values[.stageManager] = backend.applied
        let engine = try SettingsEngine(backend: backend, store: store)
        try await engine.set(.oneWindowAtATime, enabled: true, intensity: 0.5)
        backend.ignoredDisable = [.stageManager]
        await expectThrows(try await engine.set(.oneWindowAtATime, enabled: false, intensity: 0.5))
        await expectEqual(store.journal.stageManagerBeforeOneWindow, backend.applied)
        backend.ignoredDisable = []
        try await engine.set(.oneWindowAtATime, enabled: false, intensity: 0.5)
        await expectFalse(try backend.read(.stageManager).enabled == true)
        await expectTrue(try await engine.restoreIndividual().isEmpty)
        await expectEqual(backend.values[.stageManager], backend.applied)
    }

    func testDimmingDoesNotStopStageWithoutItsSnapshot() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        backend.values[.stageManager] = backend.applied
        backend.failSnapshot = [.stageManager]
        let engine = try SettingsEngine(backend: backend, store: store)
        await expectThrows(try await engine.set(.dimBackground, enabled: true, intensity: 0.5))
        await expectEqual(backend.writes, 0)
        let issues = try await engine.enableMonk(intensity: 0.5, focusMode: .dimBackground)
        await expectTrue(issues.contains { $0.feature == .stageManager })
        await expectTrue(issues.contains { $0.feature == .dimBackground })
        await expectEqual(backend.values[.stageManager], backend.applied)
        await expectFalse(try backend.read(.dimBackground).enabled == true)
    }
}
