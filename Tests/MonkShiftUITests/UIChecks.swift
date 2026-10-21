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

@MainActor private final class FakeAccessibility: AccessibilityPermissionClient {
    var allowed = true
    var prompts = 0
    func isTrusted(prompt: Bool) -> Bool { if prompt { prompts += 1 }; return allowed }
}

@MainActor private final class FakeSettings: ObservedSettingsBackend {
    var values = Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0, false) })
    var amount = 0.5
    var dimmingAmount = 0.5
    var changes: [String] = []
    var intensities: [Double] = []
    var failFeature: Feature?
    var failRestoreFeature: Feature?
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
    func dimmingIntensity() -> Double { dimmingAmount }
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
        if feature == .dimBackground { dimmingAmount = intensity; intensities.append(intensity) }
    }
    func disable(_ feature: Feature) async throws { values[feature] = false; changes.append("disable:\(feature.rawValue)") }
    func restore(_ feature: Feature, from data: Data) async throws {
        if failRestoreFeature == feature { throw MonkError("Fixture restore failed") }
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
    let accessibility = FakeAccessibility()
    let backend: FakeSettings
    let model: AppModel
    private let defaults: UserDefaults
    private let suite = "MonkShiftUIChecks.\(UUID().uuidString)"

    init() {
        backend = FakeSettings(directory: directory)
        defaults = UserDefaults(suiteName: suite)!
        model = AppModel(directory: directory, backend: backend,
            permissions: PermissionManager(client: permission), shortcuts: ShortcutManager(installHandler: false),
            accessibility: AccessibilityPermissionManager(client: accessibility),
            defaults: defaults)
    }
    func start() async throws {
        model.refresh()
        try await until { !self.model.refreshing }
        try require(model.canChange, "Fixture did not become available")
    }
    func restartedModel() -> AppModel {
        AppModel(directory: directory, backend: backend, permissions: PermissionManager(client: permission),
            shortcuts: ShortcutManager(installHandler: false), accessibility: AccessibilityPermissionManager(client: accessibility),
            defaults: defaults)
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
            ("Focus handoff retains the layer until its new anchor is ready", DimmingChecks.testFocusHandoffKeepsTheLayerVisible),
            ("Menus retain the layer and allow new window focus", DimmingChecks.testMenuKeepsLayerAndAcceptsNewWindow),
            ("Slow AX menu replies without notifications retain the visible anchor", DimmingChecks.testMenuWithoutNotificationsRetainsVisibleWindow),
            ("Explicit menu events survive a missing inferred menu", DimmingChecks.testExplicitMenusSurviveMissingInferredMenu),
            ("Unresolved AX reads preserve confirmed history for the next menu", DimmingChecks.testUnresolvedReadingKeepsConfirmedHistoryForNextMenu),
            ("Repeated menus without document refocus keep the layer visible", DimmingChecks.testRepeatedMenusWithoutDocumentRefocus),
            ("Accessory popups at normal level preserve the document anchor", DimmingChecks.testAccessoryPopupDoesNotBecomeDocumentAnchor),
            ("Popup reader classifies before geometry or WindowServer publication", DimmingChecks.testPopupReaderIgnoresUnpublishedOrIncompleteGeometry),
            ("Reader results retain dimming across repeated unpublished Stats panels", DimmingChecks.testPopupReaderKeepsDimmingThroughRepeatedStatsPanels),
            ("Reader distinguishes real settings and ambiguous normal windows", DimmingChecks.testReaderKeepsSettingsAndAmbiguousFocusRules),
            ("Visible anchor retention rejects stale and ambiguous focus", DimmingChecks.testVisibleWindowRetentionRejectsStaleOrAmbiguousFocus),
            ("Closing a menu bounds missing focus retention", DimmingChecks.testMenuCloseExpiresMissingFocus),
            ("Menus never delay unsafe transitions or disable", DimmingChecks.testMenuDoesNotDelayUnsafeChanges),
            ("Nested menus and transient panels exclude persistent status icons", DimmingChecks.testNestedMenuSourcesAndDetection),
            ("Focus handoff removes unknown focus after its bounded deadline", DimmingChecks.testFocusHandoffDeadlineRemovesUnknownFocus),
            ("Space changes and permission loss bypass focus handoff delay", DimmingChecks.testUnsafeFocusChangesClearImmediately),
            ("Dimming validation waits for WindowServer publication", DimmingChecks.testDeferredWindowServerPublication),
            ("Dimming validation bounds genuine ordering failures", DimmingChecks.testOrderingFailuresAreBounded),
            ("Cancelled ordering validation ignores stale window state", DimmingChecks.testOrderingCancellationDoesNotReadStaleWindows),
            ("Background dimming lifecycle caps intensity and stops on exit", DimmingChecks.testLifecycleAndIntensity),
            ("Background dimming suspends on permission loss and grouping conflict", DimmingChecks.testPermissionAndConflict),
            ("Background dimming hides on missing focus and ordering errors", DimmingChecks.testMissingFocusAndOrderingFailure),
            ("Background dimming restores state and rejects invalid intensity", DimmingChecks.testStateRestorationAndInvalidIntensity),
            ("Focused metadata matching rejects ambiguous and foreign windows", DimmingChecks.testMetadataMatching),
            ("Focus selection survives restart and Monk Mode uses that choice", testFocusChoicePersistence),
            ("Rapid focus switching remains exclusive and restores both baselines", testRapidFocusSwitching),
            ("Dimming menu slider is independent and limited to 90 percent", testDimmingMenu),
            ("Startup asks for Accessibility once without blocking other features", testAccessibilityStartup),
            ("Revoked Accessibility blocks queued dimming without disabling the other mode", testQueuedAccessibilityRevocation),
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
            ("Queued Monk Mode and Restore All preserve the baseline", testModeAndRestore),
            ("App Intents enable, toggle and disable the saved session", testAppIntentActions),
            ("Repeated intent enable preserves the original baseline", testIntentRepeatedEnable),
            ("Intent completion waits for mutation and read-back", testIntentWaitsForCompletion),
            ("Intent during initial refresh waits for the existing queue", testIntentDuringRefresh),
            ("Intent permission failure is reported without mutations", testIntentPermissionFailure),
            ("Permission revocation completes queued intents with an error", testIntentQueuedRevocation),
            ("Intent apply errors are returned and remain recoverable", testIntentApplyFailure),
            ("Intent restore failures retain records for retry", testIntentRestoreFailure),
            ("Intent finalization failure is returned to its caller", testIntentFinalizationFailure),
            ("Intents fail cleanly during startup and shutdown", testIntentLifecycle),
            ("Reduce Motion menu control and Monk Mode share restoration", { try await testDisplayMenuControl(.reduceMotion) }),
            ("Desktop visibility menu control and Monk Mode share restoration", { try await testDisplayMenuControl(.hideDesktopItems) })
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(checks.count) UI checks, \(failures) failures. Fake settings/permissions only; no real shortcuts or OS setting changes.")
        if failures > 0 { exit(1) }
    }

    @MainActor private static func testFocusChoicePersistence() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.model.dimmingIntensity = 0.75
        f.model.commitDimmingIntensity()
        f.model.set(.dimBackground, enabled: true)
        try await until { !f.model.busy }
        f.model.set(.dimBackground, enabled: false)
        try await until { !f.model.busy }
        try require(f.model.preferredFocusMode == .dimBackground, "Turning off a mode forgot the selected choice")
        let restarted = f.restartedModel()
        defer { restarted.shortcuts.shutdown(); restarted.shutdown() }
        restarted.refresh()
        try await until { !restarted.refreshing }
        try require(restarted.preferredFocusMode == .dimBackground && restarted.dimmingIntensity == 0.75,
            "Restart lost the mode choice or its independent intensity")
        try await restarted.performMonkMode(.enable)
        try require(f.backend.values[.dimBackground] == true && f.backend.values[.oneWindowAtATime] == false &&
            f.backend.dimmingAmount == 0.75 && f.backend.amount == 0.5,
            "Monk Mode ignored the selected mode or mixed up the two intensities")
        try await restarted.performMonkMode(.disable)
        try require(f.backend.values[.dimBackground] == false && f.backend.values[.oneWindowAtATime] == false,
            "Monk Mode did not restore the pre-session focus states")
    }

    @MainActor private static func testRapidFocusSwitching() async throws {
        let f = Fixture(); defer { f.close() }
        f.backend.values[.oneWindowAtATime] = true
        try await f.start()
        f.backend.holdApply = true
        f.model.set(.dimBackground, enabled: true)
        try await until { f.backend.blockedApply != nil }
        f.model.set(.oneWindowAtATime, enabled: true)
        f.model.set(.dimBackground, enabled: true)
        try require(f.model.displayedEnabled(.dimBackground) == true && f.model.displayedEnabled(.oneWindowAtATime) == false,
            "Queued focus controls showed two enabled modes")
        f.backend.releaseApply()
        try await until { !f.model.busy }
        try require(f.backend.values[.dimBackground] == true && f.backend.values[.oneWindowAtATime] == false,
            "Rapid focus changes ended with the wrong mode")
        f.model.restoreAll()
        try await until { !f.model.busy }
        try require(f.backend.values[.dimBackground] == false && f.backend.values[.oneWindowAtATime] == true,
            "Restore All lost the originally enabled Stage Manager mode")
    }

    @MainActor private static func testDimmingMenu() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        let menu = SettingsMenuController(model: f.model, showWindow: {}, quit: {})
        f.model.onRefresh = { [weak menu] in menu?.update() }
        guard let row = menu.menu.items.first(where: { $0.representedObject as? String == Feature.dimBackground.rawValue }),
              let action = row.action else { throw UIFailure(description: "Dimming menu toggle missing") }
        try require(NSApp.sendAction(action, to: row.target, from: row), "Dimming menu action failed")
        try await until { !f.model.busy }
        guard let view = menu.menu.items.compactMap(\.view).first(where: {
            $0.subviews.compactMap { $0 as? NSSlider }.first?.maxValue == 90
        }), let slider = view.subviews.compactMap({ $0 as? NSSlider }).first else {
            throw UIFailure(description: "Separate 0–90% dimming menu slider missing")
        }
        let identity = ObjectIdentifier(view)
        slider.doubleValue = 90
        try require(slider.isEnabled && slider.sendAction(slider.action, to: slider.target), "Dimming slider did not commit")
        try await until { !f.model.busy }
        try require(f.backend.dimmingAmount == 0.9 && f.model.intensity == 0.5 && f.backend.amount == 0.5,
            "Dimming menu slider changed grayscale intensity")
        menu.update()
        try require(menu.menu.items.compactMap(\.view).contains { ObjectIdentifier($0) == identity }, "Dimming slider was recreated")
    }

    @MainActor private static func testAccessibilityStartup() async throws {
        let f = Fixture(); defer { f.close() }
        f.accessibility.allowed = false
        f.model.requestStartupPermissions()
        f.model.requestStartupPermissions()
        try await until { !f.model.refreshing }
        try require(f.accessibility.prompts == 1 && f.model.canChange && f.model.states[.dimBackground]?.available == false,
            "Startup repeated Accessibility prompts or blocked unrelated controls")
        f.model.set(.oneWindowAtATime, enabled: true)
        try await until { !f.model.busy }
        try require(f.backend.values[.oneWindowAtATime] == true, "Denied Accessibility blocked Stage Manager mode")
        f.accessibility.allowed = true
        f.model.refresh()
        try await until { !f.model.refreshing }
        try require(f.model.canAdjustDimmingIntensity, "Accessibility grant did not unlock dimming controls")
    }

    @MainActor private static func testQueuedAccessibilityRevocation() async throws {
        let f = Fixture(); defer { f.close() }
        f.backend.values[.oneWindowAtATime] = true
        try await f.start()
        f.backend.holdRead = true
        f.model.refresh()
        try await until { f.backend.blockedRead != nil }
        f.model.set(.dimBackground, enabled: true)
        f.accessibility.allowed = false
        f.backend.releaseRead()
        try await until { !f.model.refreshing && !f.model.busy }
        try require(f.backend.values[.oneWindowAtATime] == true && f.backend.values[.dimBackground] == false &&
            f.model.issue(for: .dimBackground)?.contains("Accessibility") == true,
            "Revoked Accessibility disabled the existing mode or enabled a queued dimming effect")
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
        let control = original.first { $0.title.hasPrefix("Grayscale intensity") }!
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

    @MainActor private static func failureMessage(_ operation: () async throws -> Void) async throws -> String {
        do { try await operation() }
        catch { return error.localizedDescription }
        throw UIFailure(description: "Expected the shortcut to report a failure")
    }

    @MainActor private static func testDisplayMenuControl(_ feature: Feature) async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        let controller = SettingsMenuController(model: f.model, showWindow: {}, quit: {})
        f.model.onRefresh = { [weak controller] in controller?.update() }
        guard let row = controller.menu.items.first(where: { $0.representedObject as? String == feature.rawValue }),
              let action = row.action else { throw UIFailure(description: "\(feature.title) menu control is missing") }
        try require(row.title == feature.title && row.state == .off && row.isEnabled, "\(feature.title) menu state is incorrect")
        try require(NSApp.sendAction(action, to: row.target, from: row), "\(feature.title) menu action was not handled")
        try await until { !f.model.busy }
        try require(f.backend.values[feature] == true && row.state == .on && !f.model.hasSession,
            "Individual \(feature.title) control did not update independently")
        try await f.model.performMonkMode(.enable)
        try await f.model.performMonkMode(.disable)
        try require(f.backend.values[feature] == true && row.state == .on,
            "Disabling Monk Mode overwrote the earlier individual \(feature.title) setting")
        f.model.restoreAll()
        try await until { !f.model.busy }
        try require(f.backend.values[feature] == false && row.state == .off,
            "Restore All did not restore the original \(feature.title) baseline")
    }

    @MainActor private static func testAppIntentActions() async throws {
        let f = Fixture(); defer { f.close(); MonkModeIntentHandler.shared.model = nil }
        try await f.start()
        MonkModeIntentHandler.shared.model = f.model
        _ = try await EnableMonkModeIntent().perform()
        try require(f.model.hasSession && Feature.allCases.filter { $0 != .dimBackground }.allSatisfy { f.backend.values[$0] == true } &&
            f.backend.values[.dimBackground] == false, "Enable intent did not apply the selected focus mode")
        _ = try await ToggleMonkModeIntent().perform()
        try require(!f.model.hasSession && f.backend.values.values.allSatisfy { !$0 }, "Toggle intent did not restore the session")
        _ = try await ToggleMonkModeIntent().perform()
        try require(f.model.hasSession, "Toggle intent did not enable a new session")
        _ = try await DisableMonkModeIntent().perform()
        let changes = f.backend.changes
        _ = try await DisableMonkModeIntent().perform()
        try require(!f.model.hasSession && f.backend.values.values.allSatisfy { !$0 } && f.backend.changes == changes,
            "Disable intent changed settings without a saved session")
    }

    @MainActor private static func testIntentRepeatedEnable() async throws {
        let f = Fixture(); defer { f.close() }
        f.backend.values[.hideDock] = true
        try await f.start()
        try await f.model.performMonkMode(.enable)
        let original = try FileRestoreStore(url: f.directory.appendingPathComponent("restore.json")).load()
        try await f.model.performMonkMode(.enable)
        let saved = try FileRestoreStore(url: f.directory.appendingPathComponent("restore.json")).load()
        try require(original == saved && f.model.hasSession, "Repeated enable toggled off or replaced the original snapshot")
        try await f.model.performMonkMode(.disable)
        try require(f.backend.values[.hideDock] == true && f.backend.values[.hideMenuBar] == false,
            "Disable did not restore the pre-session baseline")
    }

    @MainActor private static func testIntentWaitsForCompletion() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.backend.holdApply = true
        var completed = false
        let action = Task { @MainActor in
            try await f.model.performMonkMode(.enable)
            completed = true
        }
        try await until { f.backend.blockedApply != nil }
        try require(!completed, "Intent reported success before the system mutation finished")
        f.backend.holdRead = true
        f.backend.releaseApply()
        try await until { f.backend.blockedRead != nil }
        try require(!completed, "Intent reported success before read-back finished")
        f.backend.releaseRead()
        try await action.value
        try require(completed && f.model.hasSession && f.model.states[.hideDock]?.enabled == true,
            "Intent completed without updating the saved and observed state")
    }

    @MainActor private static func testIntentDuringRefresh() async throws {
        let f = Fixture(); defer { f.close() }
        f.backend.holdRead = true
        f.model.refresh()
        try await until { f.backend.blockedRead != nil }
        let action = Task { @MainActor in try await f.model.performMonkMode(.toggle) }
        try await until { f.model.requestedSession == true }
        try require(f.backend.changes.isEmpty, "Intent interleaved mutations with initial refresh")
        f.backend.releaseRead()
        try await action.value
        try require(f.model.hasSession, "Intent was lost during startup refresh")
    }

    @MainActor private static func testIntentPermissionFailure() async throws {
        let f = Fixture(); defer { f.close() }
        f.permission.result = OSStatus(errAEEventWouldRequireUserConsent)
        let message = try await failureMessage { try await f.model.performMonkMode(.toggle) }
        try require(message.contains("Automation permission") && f.backend.changes.isEmpty && !f.model.hasPendingChanges,
            "Denied intent changed settings, stayed queued or failed without onboarding guidance")
    }

    @MainActor private static func testIntentQueuedRevocation() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.backend.holdApply = true
        let enable = Task { @MainActor in try await f.model.performMonkMode(.enable) }
        try await until { f.backend.blockedApply != nil }
        let disable = Task { @MainActor in
            try await failureMessage { try await f.model.performMonkMode(.disable) }
        }
        try await until { f.model.requestedSession == false }
        f.permission.result = OSStatus(errAEEventNotPermitted)
        f.backend.releaseApply()
        try await enable.value
        let message = try await disable.value
        try require(message.contains("Automation permission") && f.model.hasSession && !f.model.hasPendingChanges,
            "Revoked intent succeeded, lost its restore records or never completed")
        try require(!f.backend.changes.contains { $0.hasPrefix("restore:") }, "Revoked intent restored settings")
    }

    @MainActor private static func testIntentApplyFailure() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.backend.failFeature = .hideDock
        let message = try await failureMessage { try await f.model.performMonkMode(.enable) }
        try require(message.contains("Fixture write failed") && f.model.hasSession, "Partial apply was reported as success or lost its session")
        f.backend.failFeature = nil
        try await f.model.performMonkMode(.disable)
        try require(!f.model.hasSession && f.backend.values.values.allSatisfy { !$0 }, "Failed enable was not recoverable")
    }

    @MainActor private static func testIntentRestoreFailure() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        try await f.model.performMonkMode(.enable)
        f.backend.failRestoreFeature = .hideDock
        let message = try await failureMessage { try await f.model.performMonkMode(.disable) }
        let journal = try FileRestoreStore(url: f.directory.appendingPathComponent("restore.json")).load()
        try require(message.contains("Fixture restore failed") && journal.monk.count == 1 && journal.monk[Feature.hideDock.rawValue] != nil,
            "Failed restore was reported as success or its retry record was lost")
        f.backend.failRestoreFeature = nil
        try await f.model.performMonkMode(.disable)
        try require(!f.model.hasSession && f.backend.values.values.allSatisfy { !$0 }, "Disable retry did not finish restoration")
    }

    @MainActor private static func testIntentFinalizationFailure() async throws {
        let f = Fixture(); defer { f.close() }
        try await f.start()
        f.backend.failFinishOnce = true
        let message = try await failureMessage { try await f.model.performMonkMode(.enable) }
        try require(message.contains("Fixture finalization failed") && f.model.hasSession,
            "Finalization failure was reported as success or lost the restore session")
    }

    @MainActor private static func testIntentLifecycle() async throws {
        let handler = MonkModeIntentHandler()
        let startup = try await failureMessage { try await handler.perform(.toggle) }
        try require(startup.contains("starting"), "Missing app model was not reported")
        let f = Fixture(); defer { f.close() }
        try await f.start()
        handler.model = f.model
        _ = f.model.prepareToQuit {}
        let shutdown = try await failureMessage { try await handler.perform(.toggle) }
        try require(shutdown.contains("quitting") && f.backend.changes.isEmpty, "Intent changed settings during shutdown")
    }
}
