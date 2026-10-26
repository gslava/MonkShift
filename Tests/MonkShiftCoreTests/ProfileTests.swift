import Foundation
import MonkShiftCore

@MainActor final class ProfileTests {
    private func settings(_ enabled: Set<Feature> = [], mode: Feature = .oneWindowAtATime) -> ProfileSettings {
        ProfileSettings(values: Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0, enabled.contains($0)) }),
            intensity: 0.7, dimmingIntensity: 0.65, focusMode: mode)
    }

    func testLibraryRoundTripAndNames() async throws {
        let oneWindow = settings([.oneWindowAtATime], mode: .dimBackground).normalized
        await expectEqual(oneWindow.focusMode, .oneWindowAtATime)
        await expectEqual(oneWindow.values[.stageManager], true)
        await expectEqual(oneWindow.values[.hideRecentApps], false)
        var implicitRecentApps = settings([.oneWindowAtATime])
        implicitRecentApps.values.removeValue(forKey: .hideRecentApps)
        await expectEqual(implicitRecentApps.normalized.values[.hideRecentApps], true)
        let both = settings([.oneWindowAtATime, .dimBackground], mode: .dimBackground).normalized
        await expectEqual(both.values[.oneWindowAtATime], false)
        await expectEqual(both.values[.dimBackground], true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileLibrary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileProfileStore(url: directory.appendingPathComponent("profiles.json"))
        await expectEqual(try store.load(), nil)
        var library = ProfileLibrary(settings: settings([.hideDock, .dimBackground], mode: .dimBackground))
        let original = library.selected
        try library.add(name: "  Reading  ")
        await expectEqual(library.selected.name, "Reading")
        await expectEqual(library.selected.settings, original.settings)
        await expectThrows(try library.add(name: "reading"))
        await expectThrows(try library.add(name: "Default"))
        await expectThrows(try library.add(name: "  "))
        await expectThrows(try library.add(name: String(repeating: "x", count: 65)))
        try store.save(library)
        await expectEqual(try store.load(), library)
        await expectEqual(library.profiles.first, original)
    }

    func testInvalidLibrariesPreserveFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BadProfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("profiles.json")
        let store = FileProfileStore(url: url)
        let valid = ProfileLibrary(settings: settings())
        try store.save(valid)
        let original = try Data(contentsOf: url)
        for failure in 0..<5 {
            var invalid = valid
            switch failure {
            case 0: invalid.version = 2
            case 1: invalid.selectedID = "missing"
            case 2: invalid.profiles.append(invalid.selected)
            case 3: invalid.profiles[0].settings.intensity = 1.1
            default: invalid.profiles[0].settings.dimmingIntensity = 0.95
            }
            await expectThrows(try store.save(invalid))
            await expectEqual(try Data(contentsOf: url), original)
        }
        let corrupt = Data("preserve this invalid file".utf8)
        try corrupt.write(to: url)
        await expectThrows(try store.load())
        await expectEqual(try Data(contentsOf: url), corrupt)
    }

    func testSwitchesSaveEveryBaselineBeforeMutation() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        backend.beforeWrite = {
            for feature in Feature.allCases {
                await expectEqual(store.journal.individual[feature.rawValue], backend.initial)
            }
        }
        await expectTrue(try await engine.applyProfile(settings([.oneWindowAtATime, .hideRecentApps, .grayscale])).isEmpty)
        await expectEqual(backend.values[.stageManager], backend.applied)
        await expectEqual(backend.values[.hideRecentApps], backend.applied)
        await expectEqual(backend.intensities[.grayscale], 0.7)
        backend.beforeWrite = nil
        let baseline = store.journal.individual
        await expectTrue(try await engine.applyProfile(settings([.dimBackground], mode: .dimBackground)).isEmpty)
        await expectEqual(try backend.read(.stageManager).enabled, false)
        await expectEqual(backend.values[.hideRecentApps], backend.initial)
        await expectEqual(backend.intensities[.dimBackground], 0.65)
        await expectEqual(store.journal.individual, baseline)
        await expectTrue(try await engine.applyProfile(settings([.oneWindowAtATime, .hideRecentApps, .grayscale])).isEmpty)
        await expectEqual(store.journal.individual, baseline)
        await expectTrue(try await engine.restoreIndividual().isEmpty)
        for feature in Feature.allCases { await expectEqual(backend.values[feature], backend.initial) }
    }

    func testSnapshotAndDiskFailureBlockProfileMutation() async throws {
        for snapshotFailure in [false, true] {
            let backend = FakeBackend(), store = MemoryStore()
            if snapshotFailure { backend.failSnapshot = [.grayscale] }
            else { store.failSave = true }
            let engine = try SettingsEngine(backend: backend, store: store)
            await expectThrows(try await engine.applyProfile(settings([.hideDock, .oneWindowAtATime])))
            await expectEqual(backend.writes, 0)
        }
    }

    func testDisabledUnavailableSettingsDoNotBlockProfile() async throws {
        for feature in [Feature.grayscale, .reduceMotion, .hideDesktopItems] {
            for readThrows in [false, true] {
                let backend = FakeBackend(), store = MemoryStore()
                backend.unavailable = [feature]
                backend.failSnapshot = [feature]
                if readThrows { backend.failRead = [feature] }
                let engine = try SettingsEngine(backend: backend, store: store)
                await expectTrue(try await engine.applyProfile(settings([.hideDock])).isEmpty)
                await expectEqual(try backend.read(.hideDock).enabled, true)
                await expectEqual(store.journal.individual[feature.rawValue], nil)
                await expectFalse(backend.events.contains("apply:\(feature.rawValue)"))
                await expectFalse(backend.events.contains("disable:\(feature.rawValue)"))
                await expectTrue(try await engine.restoreIndividual().isEmpty)
                await expectEqual(try backend.read(.hideDock).enabled, false)
            }
        }
    }

    func testOneWindowProfilePreservesExplicitRecentAppsChoice() async throws {
        for originallyHidden in [false, true] {
            let backend = FakeBackend(), store = MemoryStore()
            if originallyHidden { backend.values[.hideRecentApps] = backend.applied }
            let original = originallyHidden ? backend.applied : backend.initial
            let engine = try SettingsEngine(backend: backend, store: store)
            let profile = settings([.oneWindowAtATime])
            for _ in 0..<2 {
                await expectTrue(try await engine.applyProfile(profile).isEmpty)
                await expectEqual(try backend.read(.oneWindowAtATime).enabled, true)
                await expectEqual(try backend.read(.stageManager).enabled, true)
                await expectEqual(try backend.read(.hideRecentApps).enabled, false)
                await expectEqual(store.journal.individual[Feature.hideRecentApps.rawValue], original)
            }
            await expectTrue(try await engine.restoreIndividual().isEmpty)
            await expectEqual(backend.values[.hideRecentApps], original)
        }
    }

    func testEnabledOrUnknownSettingsStillRequireSnapshots() async throws {
        for enabled in [false, true] {
            let backend = FakeBackend(), store = MemoryStore()
            backend.failSnapshot = [.grayscale]
            if enabled { backend.unavailable = [.grayscale] }
            else { backend.unknown = [.grayscale] }
            let engine = try SettingsEngine(backend: backend, store: store)
            await expectThrows(try await engine.applyProfile(settings(enabled ? [.hideDock, .grayscale] : [.hideDock])))
            await expectEqual(backend.writes, 0)
            await expectEqual(store.journal, RestoreJournal())
        }
    }

    func testUnavailableFocusDependenciesStillRequireSnapshots() async throws {
        for (mode, dependency) in [(Feature.oneWindowAtATime, Feature.dimBackground), (.dimBackground, .stageManager)] {
            let backend = FakeBackend(), store = MemoryStore()
            backend.values[mode.alternativeFocusMode!] = backend.applied
            backend.unavailable = [dependency]
            backend.failSnapshot = [dependency]
            let engine = try SettingsEngine(backend: backend, store: store)
            await expectThrows(try await engine.applyProfile(settings([mode], mode: mode)))
            await expectEqual(backend.writes, 0)
            await expectEqual(store.journal, RestoreJournal())
        }
    }

    func testProfileFailuresRemainRecoverableAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRestoreStore(url: directory.appendingPathComponent("restore.json"))
        let backend = FakeBackend()
        backend.failApply = [.grayscale]
        let engine = try SettingsEngine(backend: backend, store: store)
        let issues = try await engine.applyProfile(settings([.hideDock, .grayscale]))
        await expectEqual(issues.map(\.feature), [.grayscale])
        let restarted = try SettingsEngine(backend: backend, store: store)
        await expectEqual(restarted.journal.individual[Feature.grayscale.rawValue], backend.initial)
        await expectTrue(try await restarted.restoreIndividual().isEmpty)
        for feature in Feature.allCases { await expectEqual(backend.values[feature], backend.initial) }
    }

    func testProfileWithinMonkPreservesSessionBaseline() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        await expectTrue(try await engine.enableMonk(intensity: 0.5).isEmpty)
        let baseline = engine.journal.monk
        await expectTrue(try await engine.applyProfile(settings([.dimBackground], mode: .dimBackground)).isEmpty)
        await expectTrue(try await engine.applyProfile(settings([.oneWindowAtATime])).isEmpty)
        await expectEqual(engine.journal.monk, baseline)
        await expectTrue(try await engine.restoreMonk().isEmpty)
        for feature in Feature.allCases { await expectEqual(backend.values[feature], backend.initial) }
    }

    func testProfileOperationsRejectInterleaving() async throws {
        let backend = FakeBackend(), store = MemoryStore()
        let engine = try SettingsEngine(backend: backend, store: store)
        backend.beforeSnapshot = { _ in
            do {
                try await engine.set(.hideMenuBar, enabled: true, intensity: 0.5)
                await expectTrue(false)
            } catch { /* The whole profile group must stay serialized. */ }
        }
        await expectTrue(try await engine.applyProfile(settings([.hideDock])).isEmpty)
        await expectEqual(try backend.read(.hideMenuBar).enabled, false)
    }
}
