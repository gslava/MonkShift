import AppKit
import Carbon
import MonkShiftCore

private struct UIFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw UIFailure(description: message) }
}

@MainActor private final class FakePermission: AutomationPermissionClient {
    var result: OSStatus = noErr
    var checks = 0
    func status(ask: Bool) async -> OSStatus { checks += 1; return result }
    func startSystemEvents() async throws { throw UIFailure(description: "Unexpected service launch") }
}

@MainActor private final class FakeSettings: ObservedSettingsBackend {
    var values = Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0, false) })
    var amount = 0.5
    var changes: [String] = []
    var intensities: [Double] = []
    var failFeature: Feature?
    var holdRead = false
    var holdApply = false
    var holdIntensity = false
    var failFinishOnce = false
    var blockedRead: CheckedContinuation<Void, Never>?
    var blockedApply: CheckedContinuation<Void, Never>?
    var blockedIntensity: CheckedContinuation<Void, Never>?
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func read(_ feature: Feature) async throws -> FeatureState {
        if holdRead {
            holdRead = false
            await withCheckedContinuation { blockedRead = $0 }
        }
        return FeatureState(enabled: values[feature])
    }
    func intensity() async throws -> Double {
        if holdIntensity {
            holdIntensity = false
            await withCheckedContinuation { blockedIntensity = $0 }
        }
        return amount
    }
    func snapshot(_ feature: Feature) async throws -> Data { try JSONEncoder().encode(values[feature]!) }
    func apply(_ feature: Feature, intensity: Double) async throws {
        let journal = try FileRestoreStore(url: directory.appendingPathComponent("restore.json")).load()
        try require(journal.individual[feature.rawValue] != nil || journal.monk[feature.rawValue] != nil,
            "Mutation began before its snapshot was persisted")
        if holdApply {
            holdApply = false
            await withCheckedContinuation { blockedApply = $0 }
        }
        changes.append("apply:\(feature.rawValue)")
        if failFeature == feature { throw MonkError("Fixture write failed") }
        values[feature] = true
        if feature == .grayscale { amount = intensity; intensities.append(intensity) }
    }
    func disable(_ feature: Feature) async throws { values[feature] = false; changes.append("disable:\(feature.rawValue)") }
    func restore(_ feature: Feature, from data: Data) async throws {
        values[feature] = try JSONDecoder().decode(Bool.self, from: data)
        changes.append("restore:\(feature.rawValue)")
    }
    func finishChanges() async throws {
        if failFinishOnce { failFinishOnce = false; throw MonkError("Fixture finalization failed") }
    }
    func releaseRead() { blockedRead?.resume(); blockedRead = nil }
    func releaseApply() { blockedApply?.resume(); blockedApply = nil }
    func releaseIntensity() { blockedIntensity?.resume(); blockedIntensity = nil }
}

@MainActor private final class Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MonkShiftUI-\(UUID().uuidString)")
    let permission = FakePermission()
    let backend: FakeSettings
    let model: AppModel
    private let defaults: UserDefaults
    private let suite = "MonkShiftUIChecks.\(UUID().uuidString)"

    init() {
        backend = FakeSettings(directory: directory)
        defaults = UserDefaults(suiteName: suite)!
        model = AppModel(directory: directory, backend: backend,
            permissions: PermissionManager(client: permission), shortcuts: ShortcutManager(installHandler: false),
            defaults: defaults)
    }
    func start() async throws {
        model.refresh()
        try await until { !self.model.refreshing }
        try require(model.canChange, "Fixture did not become available")
    }
    func close() {
        backend.releaseRead()
        backend.releaseApply()
        backend.releaseIntensity()
        model.shortcuts.shutdown()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor private func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        if ContinuousClock.now > deadline { throw UIFailure(description: "Timed out waiting for fixture work") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@main enum UIChecks {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("Refresh keeps controls stable and queues new input", testRefreshQueuesInput),
            ("Rapid checkbox changes execute in order without bouncing", testRapidToggles),
            ("Failed change rolls back and does not block the next setting", testFailureRecovery),
            ("Queued slider commits retain their captured intensity", testIntensityQueue),
            ("Slider commit supersedes an in-flight intensity refresh", testIntensityDuringRefresh),
            ("Finalization error survives later queued changes", testFinalizationError),
            ("Revoked permission cancels pending mutations", testRevocation),
            ("Permission is checked again for each queued mutation", testRevocationDuringQueue),
            ("Native menu items and slider survive refresh and apply", testMenuIdentity),
            ("Quit waits for accepted changes without allowing new ones", testQuitDuringChanges),
            ("Quit waits for input queued during refresh", testQuitDuringRefresh),
            ("Quit completes when permission cancels the queue", testQuitAfterRevocation),
            ("Idle Quit needs no deferred completion", testIdleQuit),
            ("Queued Monk Mode and Restore All preserve the baseline", testModeAndRestore)
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(checks.count) UI checks, \(failures) failures. Fake settings/permissions only; no real shortcuts or OS setting changes.")
        if failures > 0 { exit(1) }
    }

    @MainActor private static func testRefreshQueuesInput() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        let title = f.model.statusTitle
        f.backend.holdRead = true
        f.model.refresh()
        try await until { f.backend.blockedRead != nil }
        try require(f.model.canChange && f.model.statusTitle == title, "Refresh changed availability or status title")
        f.model.set(.hideDock, enabled: true)
        try require(f.model.displayedEnabled(.hideDock) == true && f.backend.changes.isEmpty,
            "Input during refresh was lost or interleaved with reads")
        f.backend.releaseRead()
        try await until { !f.model.refreshing && !f.model.busy }
        try require(f.backend.values[.hideDock] == true, "Queued action was lost after refresh")
    }

    @MainActor private static func testRapidToggles() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        let title = f.model.statusTitle
        f.backend.holdApply = true
        f.model.toggle(.hideDock)
        try await until { f.backend.blockedApply != nil }
        try require(f.model.canChange && f.model.statusTitle == title, "Apply disabled controls or replaced the title")
        f.model.toggle(.hideMenuBar)
        f.model.toggle(.hideDock)
        try require(f.model.displayedEnabled(.hideDock) == false && f.model.displayedEnabled(.hideMenuBar) == true,
            "Latest requested checkbox states were not retained")
        var bounced = false
        f.model.onRefresh = { if f.model.displayedEnabled(.hideDock) != false { bounced = true } }
        defer { f.model.onRefresh = nil }
        f.backend.releaseApply()
        try await until { !f.model.busy }
        try require(!bounced, "Checkbox bounced to an older in-flight value")
        try require(f.backend.changes == ["apply:hideDock", "apply:hideMenuBar", "restore:hideDock"], "Changes were lost or reordered")
    }

    @MainActor private static func testFailureRecovery() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.backend.failFeature = .hideDock
        f.model.set(.hideDock, enabled: true)
        f.model.set(.hideMenuBar, enabled: true)
        try await until { !f.model.busy }
        try require(f.model.displayedEnabled(.hideDock) == false, "Failed checkbox did not return to its observed value")
        try require(f.model.issue(for: .hideDock)?.contains("Fixture write failed") == true, "Later change erased the failure")
        try require(f.backend.values[.hideMenuBar] == true, "A failed action stopped the queue")
        let saved = try FileRestoreStore(url: f.directory.appendingPathComponent("restore.json")).load()
        try require(saved.individual[Feature.hideDock.rawValue] != nil, "Failed change lost its restore record")
    }

    @MainActor private static func testIntensityQueue() async throws {
        let f = Fixture(); defer { f.close() }
        f.backend.values[.grayscale] = true
        try await f.start()
        f.backend.holdApply = true
        f.model.intensity = 0.2
        f.model.commitIntensity()
        try await until { f.backend.blockedApply != nil }
        f.model.intensity = 0.8
        f.model.commitIntensity()
        try require(f.model.canAdjustMenuIntensity, "In-flight apply disabled the menu slider")
        var bounced = false
        f.model.onRefresh = { if f.model.intensity != 0.8 { bounced = true } }
        defer { f.model.onRefresh = nil }
        f.backend.releaseApply()
        try await until { !f.model.busy }
        try require(f.backend.intensities == [0.2, 0.8], "Queued intensity values were not captured individually")
        try require(!bounced && f.model.intensity == 0.8, "Read-back replaced the latest slider value")
    }

    @MainActor private static func testRevocation() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.permission.result = OSStatus(errAEEventNotPermitted)
        f.model.set(.hideDock, enabled: true)
        f.model.set(.hideMenuBar, enabled: true)
        try await until { !f.model.busy }
        try require(!f.model.canChange && f.backend.changes.isEmpty && f.model.requestedValues.isEmpty,
            "Revoked permission allowed or retained pending mutations")
    }

    @MainActor private static func testIntensityDuringRefresh() async throws {
        let f = Fixture(); defer { f.close() }
        f.backend.values[.grayscale] = true
        try await f.start()
        f.model.intensity = 0.8
        f.backend.holdIntensity = true
        f.model.refresh()
        try await until { f.backend.blockedIntensity != nil }
        f.model.commitIntensity()
        var bounced = false
        f.model.onRefresh = { if f.model.intensity != 0.8 { bounced = true } }
        defer { f.model.onRefresh = nil }
        f.backend.releaseIntensity()
        try await until { !f.model.refreshing && !f.model.busy }
        try require(!bounced && f.backend.intensities == [0.8], "An older in-flight read overwrote the slider commit")
    }

    @MainActor private static func testFinalizationError() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.backend.failFinishOnce = true
        f.model.set(.hideDock, enabled: true)
        f.model.set(.hideMenuBar, enabled: true)
        try await until { !f.model.busy }
        try require(f.model.generalError?.contains("Fixture finalization failed") == true,
            "A later successful queued change erased the finalization failure")
    }

    @MainActor private static func testRevocationDuringQueue() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.backend.holdApply = true
        f.model.set(.hideDock, enabled: true)
        try await until { f.backend.blockedApply != nil }
        f.model.set(.hideMenuBar, enabled: true)
        f.permission.result = OSStatus(errAEEventNotPermitted)
        f.backend.releaseApply()
        try await until { !f.model.busy }
        try require(f.backend.changes == ["apply:hideDock"] && !f.model.canChange,
            "A later queued mutation skipped its permission check")
    }

    @MainActor private static func testMenuIdentity() async throws {
        let f = Fixture(); defer { f.close() }
        f.backend.values[.grayscale] = true
        try await f.start()
        let controller = SettingsMenuController(model: f.model, showWindow: {}, quit: {})
        f.model.onRefresh = { [weak controller] in controller?.update() }
        let original = controller.menu.items
        let row = original.first { $0.representedObject as? String == Feature.hideDock.rawValue }!
        let control = original.first { $0.view is GrayscaleIntensityMenuView }!
        let view = control.view!
        let slider = view.subviews.compactMap { $0 as? NSSlider }.first!
        let title = original[0].title
        let quit = original.first { $0.title == "Quit MonkShift" }!
        f.backend.holdRead = true
        f.model.refresh()
        try await until { f.backend.blockedRead != nil }
        controller.update()
        try require(row.isEnabled && slider.isEnabled && original[0].title == title, "Refresh greyed or replaced menu content")
        try require(quit.isEnabled && quit.title == "Quit MonkShift", "Refresh changed Quit's appearance")
        f.backend.holdApply = true
        f.model.toggle(.hideDock)
        f.backend.releaseRead()
        try await until { f.backend.blockedApply != nil }
        controller.update()
        try require(row.isEnabled && row.state == .on && slider.isEnabled, "Pending change disabled controls or lost its checkmark")
        try require(quit.isEnabled && quit.title == "Quit MonkShift", "Apply changed Quit's appearance")
        try require(controller.menu.items.count == original.count, "Routine work changed the menu structure")
        slider.doubleValue = 80
        _ = slider.sendAction(slider.action, to: slider.target)
        try require(f.model.intensity == 0.8, "Native slider did not retain its new value during another change")
        f.backend.releaseApply()
        try await until { !f.model.busy }
        for item in original { try require(controller.menu.items.contains { $0 === item }, "An existing native menu item was replaced") }
        try require(control.view === view && view.subviews.contains { $0 === slider }, "The native slider was recreated")
        try require(f.backend.amount == 0.8, "Native slider commit was lost while another change was in flight")
        try require(quit.isEnabled && quit.title == "Quit MonkShift", "Completion changed Quit's appearance")
    }

    @MainActor private static func testQuitDuringChanges() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.backend.holdApply = true
        f.model.set(.hideDock, enabled: true)
        try await until { f.backend.blockedApply != nil }
        f.model.set(.hideMenuBar, enabled: true)
        var completions = 0
        var finishedSafely = false
        try require(f.model.prepareToQuit {
            completions += 1
            finishedSafely = !f.model.busy && !f.model.hasPendingChanges && f.backend.values[.hideMenuBar] == true
        }, "In-flight Quit did not defer termination")
        _ = f.model.prepareToQuit { completions += 100 }
        try require(completions == 0, "Quit interrupted an in-flight mutation")
        f.model.set(.stageManager, enabled: true)
        f.backend.releaseApply()
        try await until { completions != 0 }
        try require(completions == 1 && finishedSafely, "Quit completion was repeated or ran before the queue drained")
        try require(f.backend.changes == ["apply:hideDock", "apply:hideMenuBar"], "Quit lost accepted changes or accepted new ones")
        let journal = try FileRestoreStore(url: f.directory.appendingPathComponent("restore.json")).load()
        try require(journal.individual.count == 2, "Quit ran before restoration state was persisted")
    }

    @MainActor private static func testQuitDuringRefresh() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.backend.holdRead = true
        f.model.refresh()
        try await until { f.backend.blockedRead != nil }
        f.model.set(.hideDock, enabled: true)
        var completed = false
        try require(f.model.prepareToQuit { completed = true }, "Quit ignored changes waiting for refresh")
        try require(!completed && f.backend.changes.isEmpty, "Quit interrupted the pending refresh")
        f.backend.releaseRead()
        try await until { completed }
        try require(f.backend.values[.hideDock] == true && !f.model.busy, "Quit discarded an accepted change")
    }

    @MainActor private static func testQuitAfterRevocation() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.permission.result = OSStatus(errAEEventNotPermitted)
        f.model.set(.hideDock, enabled: true)
        var completed = false
        try require(f.model.prepareToQuit { completed = true }, "Queued Quit did not defer")
        try await until { completed }
        try require(f.backend.changes.isEmpty && !f.model.hasPendingChanges, "Revoked permission did not cancel the queue safely")
    }

    @MainActor private static func testIdleQuit() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        var completed = false
        try require(!f.model.prepareToQuit { completed = true }, "Idle Quit unnecessarily deferred termination")
        try require(!completed, "Idle Quit sent a deferred reply without a deferred request")
    }

    @MainActor private static func testModeAndRestore() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.backend.holdApply = true
        f.model.toggleMonk()
        try await until { f.backend.blockedApply != nil }
        f.model.toggleMonk()
        f.model.set(.hideDock, enabled: true)
        f.model.restoreAll()
        f.backend.releaseApply()
        try await until { !f.model.busy }
        let journal = try FileRestoreStore(url: f.directory.appendingPathComponent("restore.json")).load()
        try require(journal.monk.isEmpty && journal.individual.isEmpty, "Queued restores left stale journal entries")
        try require(f.backend.values.values.allSatisfy { !$0 } && !f.model.hasSession, "Queued operations did not restore the original baseline")
    }
}
