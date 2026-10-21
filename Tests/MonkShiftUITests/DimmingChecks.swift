import AppKit
import MonkShiftCore

@MainActor private final class TrackingFixture: DimmingTracking {
    var onChange: ((DimmingTarget?) -> Void)?
    var onFocusChangeStarted: ((Bool) -> Void)?
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func refresh() {}
    func stop() { stops += 1 }
}

@MainActor private final class RenderingFixture: DimmingRendering {
    var target: DimmingTarget?
    var intensity: Double?
    var fail = false
    var events: [String] = []
    func show(below target: DimmingTarget, intensity: Double) throws {
        if fail { throw MonkError("Ordering rejected") }
        self.target = target
        self.intensity = intensity
        events.append("show:\(target.windowID)")
    }
    func hide() { target = nil; intensity = nil; events.append("hide") }
    func prepareForFocusChange() { events.append("prepare") }
}

@MainActor private final class TransitionGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async throws {
        await withCheckedContinuation { continuation in self.continuation = continuation; waiting = true }
        try Task.checkCancellation()
    }
    func release() { waiting = false; continuation?.resume(); continuation = nil }
}

@MainActor private final class DimmingFixture {
    let tracker = TrackingFixture()
    let renderer = RenderingFixture()
    var trusted = true
    var conflict = false
    var saved: [BackgroundDimmingService.State] = []
    var transitionWait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(150)) }
    lazy var service = BackgroundDimmingService(tracker: tracker, renderer: renderer,
        trusted: { self.trusted }, oneWindowEnabled: { self.conflict }, save: { self.saved.append($0) },
        transitionWait: { try await self.transitionWait() })
    let target = DimmingTarget(windowID: 42, bounds: CGRect(x: 40, y: 80, width: 800, height: 600))

    func focus(_ target: DimmingTarget?) async {
        tracker.onChange?(target)
        // read() settles the same asynchronous permission/conflict checks as a focus event.
        _ = await service.read()
    }
}

@MainActor enum DimmingChecks {
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw MonkError(message) }
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            if ContinuousClock.now > deadline { throw MonkError("Timed out waiting for dimming fixture") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static func testFocusHandoffKeepsTheLayerVisible() async throws {
        let f = DimmingFixture(), gate = TransitionGate()
        f.transitionWait = { try await gate.wait() }
        try await f.service.set(enabled: true)
        await f.focus(f.target)
        f.renderer.events.removeAll()
        f.tracker.onFocusChangeStarted?(false)
        try await until { gate.waiting }
        await f.focus(nil)
        try check(f.renderer.target == f.target && !f.renderer.events.contains("hide"),
            "App activation hid the existing layer before replacement focus was available")
        let next = DimmingTarget(windowID: 43, bounds: f.target.bounds)
        await f.focus(next)
        gate.release()
        await f.focus(next)
        try check(f.renderer.target == next && !f.renderer.events.contains("hide"),
            "A cancelled handoff timer hid the new window's layer")
        try check(f.tracker.starts == 1 && f.saved.count == 1, "Focus handoff restarted tracking or wrote user preferences")
        try await f.service.set(enabled: false)
    }

    static func testFocusHandoffDeadlineRemovesUnknownFocus() async throws {
        let f = DimmingFixture(), gate = TransitionGate()
        f.transitionWait = { try await gate.wait() }
        try await f.service.set(enabled: true)
        await f.focus(f.target)
        f.tracker.onFocusChangeStarted?(false)
        try await until { gate.waiting }
        await f.focus(nil)
        try check(f.renderer.target != nil, "Transient missing focus removed the layer immediately")
        gate.release()
        try await until { f.renderer.target == nil }
        try check(f.service.state.enabled && f.service.detail?.contains("active window") == true,
            "The handoff deadline forgot the toggle or retained an unknown-focus overlay")
        await f.focus(f.target)
        try check(f.renderer.target == f.target, "Dimming did not resume after focus recovered")
        try await f.service.set(enabled: false)
    }

    static func testUnsafeFocusChangesClearImmediately() async throws {
        for reason in 0..<3 {
            let f = DimmingFixture(), gate = TransitionGate()
            f.transitionWait = { try await gate.wait() }
            try await f.service.set(enabled: true)
            await f.focus(f.target)
            f.tracker.onFocusChangeStarted?(false)
            try await until { gate.waiting }
            if reason == 0 { f.tracker.onFocusChangeStarted?(true) } // Space/display reset
            if reason == 1 { f.trusted = false }
            if reason == 2 { f.conflict = true }
            _ = await f.service.read()
            try check(f.renderer.target == nil, "Space change, revoked permission or grouping conflict waited for the handoff deadline")
            gate.release()
            try await f.service.set(enabled: false)
        }
    }

    static func testDeferredWindowServerPublication() async throws {
        var waits = 0
        var reads = 0
        try await DimmingOrderValidation.validate(targetID: 42, overlayIDs: [43], read: {
            reads += 1
            return waits < 2 ? [42] : [42, 43]
        }, wait: { waits += 1 })
        try check(waits == 2 && reads == 2, "An unpublished overlay was rejected instead of waiting for WindowServer")
        waits = 0
        reads = 0
        try await DimmingOrderValidation.validate(targetID: 42, overlayIDs: [43], read: {
            reads += 1
            return [42, 43]
        }, wait: { waits += 1 })
        try check(waits == 1 && reads == 1, "Validation read WindowServer synchronously or kept polling after success")
    }

    static func testOrderingFailuresAreBounded() async throws {
        for targetDisappeared in [false, true] {
            var waits = 0
            var message: String?
            do {
                try await DimmingOrderValidation.validate(targetID: 42, overlayIDs: [43], read: {
                    targetDisappeared ? [] : [43, 42]
                }, wait: { waits += 1 })
            } catch { message = error.localizedDescription }
            try check(waits == 3 && message?.contains(targetDisappeared ? "no longer visible" : "behind the active window") == true,
                "Genuine ordering failure was ignored or validation was not bounded")
        }
    }

    static func testOrderingCancellationDoesNotReadStaleWindows() async throws {
        var reads = 0
        var cancelled = false
        do {
            try await DimmingOrderValidation.validate(targetID: 42, overlayIDs: [43], read: {
                reads += 1
                return [42, 43]
            }, wait: { throw CancellationError() })
        } catch is CancellationError { cancelled = true }
        try check(cancelled && reads == 0, "Cancelled validation inspected or changed a newer window state")
    }

    static func testLifecycleAndIntensity() async throws {
        let f = DimmingFixture()
        try await f.service.set(enabled: true, intensity: 1)
        await f.focus(f.target)
        try check(f.tracker.starts == 1 && f.renderer.target == f.target && f.renderer.intensity == 0.9,
            "Dimming did not start once or enforce its 90% maximum")
        try await f.service.set(enabled: true, intensity: 0)
        try check(f.renderer.target == nil && f.service.state.enabled, "Zero intensity left an overlay or forgot the toggle")
        try await f.service.set(enabled: true, intensity: 0.7)
        try check(f.renderer.intensity == 0.7 && f.tracker.starts == 1, "Intensity change restarted tracking or was lost")
        f.service.shutdown()
        try check(f.renderer.target == nil && f.service.state.enabled && f.saved.last?.enabled == true,
            "Exit failed to hide the effect or overwrote the saved preference")
        _ = await f.service.read()
        try check(f.tracker.starts == 2, "Saved effect did not resume after a new start")
        try await f.service.set(enabled: false)
        try check(f.renderer.target == nil && f.saved.last?.enabled == false, "Disable did not stop and persist")
    }

    static func testPermissionAndConflict() async throws {
        let f = DimmingFixture()
        f.trusted = false
        do { try await f.service.set(enabled: true); throw MonkError("Denied effect enabled") }
        catch { try check(!f.service.state.enabled && f.tracker.starts == 0, "Denied Accessibility started the effect") }
        f.trusted = true
        f.conflict = true
        do { try await f.service.set(enabled: true); throw MonkError("Conflicting effect enabled") }
        catch { try check(!f.service.state.enabled, "Effect enabled while one-window mode was active") }
        f.conflict = false
        try await f.service.set(enabled: true)
        await f.focus(f.target)
        f.conflict = true
        let paused = await f.service.read()
        try check(f.renderer.target == nil && paused.detail?.contains("Paused while") == true,
            "Externally enabled one-window mode did not pause dimming")
        f.conflict = false
        await f.focus(f.target)
        f.trusted = false
        let denied = await f.service.read()
        try check(!denied.available && f.renderer.target == nil && f.tracker.stops > 0,
            "Revoked Accessibility left overlays or observers running")
        f.trusted = true
        _ = await f.service.read()
        try check(f.service.state.enabled && f.tracker.starts == 2, "Granting permission did not resume the requested effect")
        try await f.service.set(enabled: false)
    }

    static func testMissingFocusAndOrderingFailure() async throws {
        let f = DimmingFixture()
        try await f.service.set(enabled: true)
        await f.focus(f.target)
        await f.focus(nil)
        try check(f.renderer.target == nil && f.service.detail?.contains("active window") == true,
            "Missing focus left a full-screen scrim visible")
        f.renderer.fail = true
        await f.focus(f.target)
        try check(f.renderer.target == nil && f.service.detail?.contains("Ordering rejected") == true,
            "Ordering failure was hidden or left a scrim")
        f.renderer.fail = false
        await f.focus(f.target)
        try check(f.renderer.target == f.target, "Next focus event did not recover after an ordering error")
        try await f.service.set(enabled: false)
    }

    static func testStateRestorationAndInvalidIntensity() async throws {
        let f = DimmingFixture()
        let baseline = f.service.state
        try await f.service.set(enabled: true, intensity: 0.8)
        try await f.service.restore(baseline)
        try check(f.service.state == baseline, "Overlay enabled/intensity baseline was not restored")
        for invalid in [Double.nan, .infinity, -.infinity] {
            do { try await f.service.set(enabled: true, intensity: invalid); throw MonkError("Invalid intensity accepted") }
            catch { try check(f.service.state == baseline, "Invalid intensity mutated state") }
        }
        let enabled = BackgroundDimmingService.State(enabled: true, intensity: 0.65)
        f.trusted = false
        do { try await f.service.restore(enabled); throw MonkError("Denied restore accepted") }
        catch { try check(f.service.state == baseline, "Denied restore mutated the baseline") }
        f.trusted = true
        try await f.service.restore(enabled)
        try check(f.service.state == enabled, "Retry did not restore the saved enabled state and intensity")
        try await f.service.set(enabled: false)
    }

    static func testMetadataMatching() async throws {
        let rect = CGRect(x: -1000, y: 80, width: 800, height: 600)
        let window = WindowMetadata(id: 42, pid: 123, layer: 0, bounds: rect)
        try check(WindowMetadata.focused(pid: 123, bounds: rect, windows: [window])?.windowID == 42,
            "Valid window on a display with negative coordinates did not match")
        try check(WindowMetadata.focused(pid: 123, bounds: rect, windows: [window, window]) == nil,
            "Ambiguous windows were guessed")
        try check(WindowMetadata.focused(pid: 456, bounds: rect, windows: [window]) == nil,
            "A different application's window was selected")
        let panel = WindowMetadata(id: 43, pid: 123, layer: 3, bounds: rect)
        try check(WindowMetadata.focused(pid: 123, bounds: rect, windows: [panel]) == nil,
            "A floating panel was mistaken for a normal window")
        try check(WindowMetadata.focused(pid: 123, bounds: .zero, windows: [window]) == nil,
            "An empty window was selected")
    }
}
