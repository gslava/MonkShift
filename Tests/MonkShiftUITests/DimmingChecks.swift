import AppKit
import ApplicationServices
import MonkShiftCore

// Owned by one FocusReader until its awaited read completes. No live AX calls.
private final class FocusAccessibilityFixture: DimmingAccessibilityReading, @unchecked Sendable {
    let window = AXUIElementCreateApplication(456)
    let hasCloseButton: Bool
    let geometryAvailable: Bool
    private(set) var requests: [String] = []
    let bounds = CGRect(x: 20, y: 30, width: 300, height: 400)

    init(hasCloseButton: Bool = false, geometryAvailable: Bool = true) {
        self.hasCloseButton = hasCloseButton
        self.geometryAvailable = geometryAvailable
    }
    func isTrusted() -> Bool { true }
    func application(pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
    func prepare(_ element: AXUIElement) {}
    func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        requests.append(attribute)
        switch attribute {
        case kAXFocusedWindowAttribute: return window
        case kAXRoleAttribute: return kAXWindowRole as CFString
        case kAXSubroleAttribute: return kAXStandardWindowSubrole as CFString
        case kAXCloseButtonAttribute: return hasCloseButton ? window : nil
        case kAXPositionAttribute:
            guard geometryAvailable else { return nil }
            var point = bounds.origin
            return AXValueCreate(.cgPoint, &point)
        case kAXSizeAttribute:
            guard geometryAvailable else { return nil }
            var size = bounds.size
            return AXValueCreate(.cgSize, &size)
        default: return nil
        }
    }
}

@MainActor private final class TrackingFixture: DimmingTracking {
    var onChange: ((DimmingTarget?) -> Void)?
    var onFocusChangeStarted: ((Bool) -> Void)?
    var onMenuTrackingChanged: ((Bool) -> Void)?
    var starts = 0
    var stops = 0
    var refreshes = 0
    func start() { starts += 1 }
    func refresh() { refreshes += 1 }
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

    static func testMenuKeepsLayerAndAcceptsNewWindow() async throws {
        let f = DimmingFixture(), gate = TransitionGate()
        f.transitionWait = { try await gate.wait() }
        try await f.service.set(enabled: true, intensity: 0.65)
        await f.focus(f.target)
        f.renderer.events.removeAll()
        f.tracker.onFocusChangeStarted?(false)
        try await until { gate.waiting }
        f.tracker.onMenuTrackingChanged?(true)
        gate.release()
        await f.focus(nil)
        f.tracker.onFocusChangeStarted?(false)
        await f.focus(nil)
        try check(f.renderer.target == f.target && f.renderer.intensity == 0.65 && !f.renderer.events.contains("hide"),
            "Opening a menu did not cancel the old focus deadline and retain the layer/intensity")
        let next = DimmingTarget(windowID: 43, bounds: f.target.bounds)
        await f.focus(next)
        try check(f.renderer.target == next && !f.renderer.events.contains("hide"),
            "A menu prevented anchoring to a newly opened real window")
        f.tracker.onMenuTrackingChanged?(false)
        try await until { gate.waiting }
        await f.focus(next)
        gate.release()
        await f.focus(next)
        try check(f.renderer.target == next && f.tracker.refreshes == 1 && f.saved.count == 1,
            "Closing a menu hid valid focus, failed to refresh, or changed saved preferences")
        try await f.service.set(enabled: false)
    }

    static func testMenuCloseExpiresMissingFocus() async throws {
        let f = DimmingFixture(), gate = TransitionGate()
        f.transitionWait = { try await gate.wait() }
        try await f.service.set(enabled: true)
        await f.focus(f.target)
        f.tracker.onMenuTrackingChanged?(true)
        await f.focus(nil)
        f.tracker.onMenuTrackingChanged?(false)
        try await until { gate.waiting }
        await f.focus(nil)
        try check(f.renderer.target == f.target, "Menu close hid the layer before focus could recover")
        gate.release()
        try await until { f.renderer.target == nil }
        try check(f.tracker.refreshes == 1 && f.service.state.enabled,
            "Menu close failed to refresh focus or forgot the enabled preference")
        try await f.service.set(enabled: false)
    }

    static func testMenuWithoutNotificationsRetainsVisibleWindow() async throws {
        let f = DimmingFixture(), gate = TransitionGate()
        f.transitionWait = { try await gate.wait() }
        try await f.service.set(enabled: true, intensity: 0.7)
        await f.focus(f.target)
        f.renderer.events.removeAll()
        let retention = DimmingFocusRetention(pid: 123, target: f.target)
        let windows = [WindowMetadata(id: f.target.windowID, pid: 123, layer: 0, bounds: f.target.bounds)]
        for (pid, transient) in [(pid_t(123), false), (pid_t(456), true)] {
            f.tracker.onFocusChangeStarted?(false)
            try await until { gate.waiting }
            let visible = retention.visibleTarget(frontmostPID: pid, transientApplication: transient, windows: windows)
            // The metadata preflight must cancel the deadline before slow AX IPC.
            await f.focus(visible)
            gate.release()
            let resolved = DimmingFocusRetention.resolve(focused: nil, retained: visible,
                canRetainWindow: true, menuActive: false)
            await f.focus(resolved)
            try check(f.renderer.target == f.target && f.renderer.intensity == 0.7 && !f.renderer.events.contains("hide"),
                "A slow/no-window AX reply hid a visible anchor without a menu notification")
        }
        try check(f.tracker.starts == 1 && f.saved.count == 1, "Menu fallback restarted observers or wrote preferences")
        try await f.service.set(enabled: false)
    }

    static func testExplicitMenusSurviveMissingInferredMenu() async throws {
        let f = DimmingFixture(), native = NSMenu()
        for nativeSource in [true, false] {
            var focus = DimmingFocusState()
            _ = focus.completeReading(pid: 123, focused: f.target, retained: nil, canRetainWindow: true, inferredMenu: false)
            if nativeSource { focus.menus.nativeMenus.insert(ObjectIdentifier(native)) }
            else { focus.menus.accessibilityMenus.insert(42) }
            let resolved = focus.completeReading(pid: 123, focused: nil, retained: f.target,
                canRetainWindow: false, inferredMenu: false)
            try check(resolved == f.target && focus.anchor?.target == f.target,
                "A transient AX reading discarded the anchor while an explicit menu was still open")
        }
    }

    static func testUnresolvedReadingKeepsConfirmedHistoryForNextMenu() async throws {
        let f = DimmingFixture()
        var focus = DimmingFocusState()
        _ = focus.completeReading(pid: 123, focused: f.target, retained: nil, canRetainWindow: true, inferredMenu: false)
        let unresolved = focus.completeReading(pid: 123, focused: nil, retained: f.target,
            canRetainWindow: false, inferredMenu: false)
        try check(unresolved == nil, "An ambiguous non-menu reading should still pause the effect")
        try check(focus.anchor?.target == f.target, "An unresolved AX reading erased confirmed window history before the next click")
        let windows = [WindowMetadata(id: f.target.windowID, pid: 123, layer: 0, bounds: f.target.bounds)]
        let retained = focus.anchor?.visibleTarget(frontmostPID: 123, transientApplication: false, windows: windows)
        let nextMenu = focus.completeReading(pid: 123, focused: nil, retained: retained,
            canRetainWindow: true, inferredMenu: false)
        try check(nextMenu == f.target, "The second menu could not recover the still-visible document anchor")
        try check(focus.anchor?.visibleTarget(frontmostPID: 456, transientApplication: false, windows: windows) == nil &&
            focus.anchor?.visibleTarget(frontmostPID: 123, transientApplication: false, windows: []) == nil,
            "Preserved history bypassed regular-app ownership or window visibility checks")
    }

    static func testRepeatedMenusWithoutDocumentRefocus() async throws {
        let f = DimmingFixture(), gate = TransitionGate(), native = NSMenu()
        f.transitionWait = { try await gate.wait() }
        var focus = DimmingFocusState()
        let windows = [WindowMetadata(id: f.target.windowID, pid: 123, layer: 0, bounds: f.target.bounds)]
        _ = focus.completeReading(pid: 123, focused: f.target, retained: nil, canRetainWindow: true, inferredMenu: false)
        try await f.service.set(enabled: true)
        await f.focus(f.target)
        f.renderer.events.removeAll()
        focus.menus.nativeMenus.insert(ObjectIdentifier(native))
        f.tracker.onMenuTrackingChanged?(true)
        for index in 0..<6 {
            focus.menus.clear()
            f.tracker.onMenuTrackingChanged?(false)
            try await until { gate.waiting }
            if index.isMultiple(of: 2) { focus.menus.accessibilityMenus.insert(42) }
            else { focus.menus.nativeMenus.insert(ObjectIdentifier(native)) }
            f.tracker.onMenuTrackingChanged?(true)
            let pid: pid_t = index.isMultiple(of: 2) ? 456 : 123
            let retained = focus.anchor?.visibleTarget(frontmostPID: pid, transientApplication: pid != 123, windows: windows)
            let resolved = focus.completeReading(pid: pid, focused: nil, retained: retained,
                canRetainWindow: false, inferredMenu: false)
            await f.focus(resolved)
            gate.release()
            await f.focus(resolved)
            try check(f.renderer.target == f.target && focus.anchor?.pid == 123 && !f.renderer.events.contains("hide"),
                "Switching/reopening menus without document refocus lost the anchor or let a stale deadline hide it")
        }
        try check(f.tracker.starts == 1 && f.saved.count == 1, "Repeated menus restarted tracking or changed preferences")
        try await f.service.set(enabled: false)
    }

    static func testAccessoryPopupDoesNotBecomeDocumentAnchor() async throws {
        // Stats 3.0.21 uses a titled, non-closable NSWindow for its menu popup.
        // These windows are level zero and pass geometry-only focus matching.
        let popup = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let settings = NSWindow(contentRect: popup.frame,
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        popup.isReleasedWhenClosed = false
        settings.isReleasedWhenClosed = false
        defer { popup.close(); settings.close() }
        try check(popup.accessibilityCloseButton() == nil && settings.accessibilityCloseButton() != nil,
            "Native popup/settings fixture did not expose the expected close-control distinction")
        for (window, expectedTransient) in [(popup, true), (settings, false)] {
            let transient = DimmingWindowClassification.isTransient(role: window.accessibilityRole()?.rawValue,
                subrole: window.accessibilitySubrole()?.rawValue, accessoryApplication: true,
                hasCloseButton: window.accessibilityCloseButton() != nil)
            try check(transient == expectedTransient, "An accessory popup became a document anchor or a real settings window was rejected")
        }
        try check(!DimmingWindowClassification.isTransient(role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
            accessoryApplication: false, hasCloseButton: false), "A regular app's custom window was treated as a menu")
        try check(DimmingWindowClassification.isTransient(role: kAXPopoverRole, subrole: nil,
            accessoryApplication: false, hasCloseButton: true), "A normal-level popover was treated as a document")
    }

    static func testPopupReaderIgnoresUnpublishedOrIncompleteGeometry() async throws {
        for geometryAvailable in [true, false] {
            let client = FocusAccessibilityFixture(geometryAvailable: geometryAvailable)
            let reader = FocusReader(accessibility: client, windows: { [] })
            let reading = await reader.read(pid: 123, transientApplication: true)
            try check(reading.target == nil && reading.menuActive && reading.canRetainWindow,
                "An unpublished/accessibility-incomplete Stats-style popup bypassed classification")
            try check(!client.requests.contains(kAXPositionAttribute) && !client.requests.contains(kAXSizeAttribute),
                "Popup retention depended on geometry arriving before WindowServer publication")
        }
    }

    static func testPopupReaderKeepsDimmingThroughRepeatedStatsPanels() async throws {
        let f = DimmingFixture(), gate = TransitionGate()
        f.transitionWait = { try await gate.wait() }
        var focus = DimmingFocusState()
        _ = focus.completeReading(pid: 321, focused: f.target, retained: nil, canRetainWindow: true, inferredMenu: false)
        let windows = [WindowMetadata(id: f.target.windowID, pid: 321, layer: 0, bounds: f.target.bounds)]
        try await f.service.set(enabled: true)
        await f.focus(f.target)
        f.renderer.events.removeAll()
        for index in 0..<4 {
            let client = FocusAccessibilityFixture(geometryAvailable: index.isMultiple(of: 2))
            let reader = FocusReader(accessibility: client, windows: { [] })
            let reading = await reader.read(pid: 123, transientApplication: true)
            let retained = focus.anchor?.visibleTarget(frontmostPID: 123, transientApplication: true, windows: windows)
            let resolved = focus.completeReading(pid: 123, focused: reading.target, retained: retained,
                canRetainWindow: reading.canRetainWindow, inferredMenu: reading.menuActive)
            f.tracker.onMenuTrackingChanged?(focus.menus.active)
            await f.focus(resolved)
            try check(f.renderer.target == f.target && focus.anchor?.pid == 321 && !f.renderer.events.contains("hide"),
                "An actual reader result for an unpublished popup hid or replaced the document anchor")
            focus.menus.clear()
            f.tracker.onMenuTrackingChanged?(false)
            try await until { gate.waiting }
            await f.focus(retained)
            gate.release()
            await f.focus(retained)
        }
        try await f.service.set(enabled: false)
    }

    static func testReaderKeepsSettingsAndAmbiguousFocusRules() async throws {
        let bounds = CGRect(x: 20, y: 30, width: 300, height: 400)
        let window = WindowMetadata(id: 99, pid: 123, layer: 0, bounds: bounds)
        let settings = FocusReader(accessibility: FocusAccessibilityFixture(hasCloseButton: true), windows: { [window] })
        let focused = await settings.read(pid: 123, transientApplication: true)
        try check(focused.target?.windowID == 99 && !focused.menuActive, "An accessory settings window no longer became the focus anchor")
        let document = FocusReader(accessibility: FocusAccessibilityFixture(), windows: { [window] })
        let regular = await document.read(pid: 123, transientApplication: false)
        try check(regular.target?.windowID == 99 && !regular.menuActive, "A regular app's custom window was treated as a popup")
        let ambiguous = FocusReader(accessibility: FocusAccessibilityFixture(hasCloseButton: true), windows: { [window, window] })
        let missing = await ambiguous.read(pid: 123, transientApplication: true)
        try check(missing.target == nil && !missing.menuActive && !missing.canRetainWindow,
            "Early classification concealed ambiguous normal-level settings windows")
    }

    static func testVisibleWindowRetentionRejectsStaleOrAmbiguousFocus() async throws {
        let f = DimmingFixture()
        let retention = DimmingFocusRetention(pid: 123, target: f.target)
        let visible = WindowMetadata(id: f.target.windowID, pid: 123, layer: 0, bounds: f.target.bounds)
        try check(retention.visibleTarget(frontmostPID: 456, transientApplication: false, windows: [visible]) == nil,
            "Switching to a different regular app reused the old window")
        for windows in [[], [WindowMetadata(id: 99, pid: 123, layer: 0, bounds: visible.bounds)],
            [WindowMetadata(id: visible.id, pid: 456, layer: 0, bounds: visible.bounds)],
            [WindowMetadata(id: visible.id, pid: 123, layer: 3, bounds: visible.bounds)]] {
            try check(retention.visibleTarget(frontmostPID: 123, transientApplication: false, windows: windows) == nil,
                "An invisible/foreign/non-normal anchor survived retention")
        }
        try check(DimmingFocusRetention.resolve(focused: nil, retained: f.target, canRetainWindow: false, menuActive: false) == nil,
            "Ambiguous focused-window metadata reused the old anchor")
        let popup = WindowMetadata(id: 99, pid: 456, layer: Int(CGWindowLevelForKey(.statusWindow)), bounds: visible.bounds)
        try check(DimmingFocusRetention.isElevatedFocus(pid: 456, bounds: popup.bounds, windows: [visible, popup]),
            "A focused system popup at status level was treated as an unknown document")
        let normal = WindowMetadata(id: 100, pid: 456, layer: 0, bounds: popup.bounds)
        try check(!DimmingFocusRetention.isElevatedFocus(pid: 456, bounds: normal.bounds, windows: [popup, normal, normal]),
            "An elevated window concealed ambiguous normal-level focus")
        try check(!DimmingFocusRetention.isElevatedFocus(pid: 789, bounds: popup.bounds, windows: [popup]),
            "Another application's popup was treated as the focused window")
        let next = DimmingTarget(windowID: 43, bounds: visible.bounds)
        try check(DimmingFocusRetention.resolve(focused: next, retained: f.target, canRetainWindow: true, menuActive: true) == next,
            "Menu retention prevented moving below a confirmed new window")
    }

    static func testMenuDoesNotDelayUnsafeChanges() async throws {
        for reason in 0..<4 {
            let f = DimmingFixture()
            try await f.service.set(enabled: true)
            await f.focus(f.target)
            f.tracker.onMenuTrackingChanged?(true)
            await f.focus(nil)
            if reason == 0 { f.tracker.onFocusChangeStarted?(true) }
            if reason == 1 { f.trusted = false }
            if reason == 2 { f.conflict = true }
            if reason == 3 { try await f.service.set(enabled: false) }
            _ = await f.service.read()
            try check(f.renderer.target == nil,
                "An open menu delayed Space reset, permission loss, grouping conflict or explicit disable")
            try await f.service.set(enabled: false)
        }
    }

    static func testNestedMenuSourcesAndDetection() async throws {
        let first = NSMenu(), second = NSMenu()
        var menus = DimmingMenuState()
        menus.nativeMenus.insert(ObjectIdentifier(first))
        menus.nativeMenus.insert(ObjectIdentifier(second))
        menus.accessibilityMenus.insert(42)
        menus.nativeMenus.remove(ObjectIdentifier(first))
        try check(menus.active, "Closing a parent menu prematurely ended nested tracking")
        menus.nativeMenus.remove(ObjectIdentifier(second))
        try check(menus.active, "Native menu close discarded external menu tracking")
        menus.clearExternal()
        try check(!menus.active, "Detached external app left stale menu tracking")
        menus.inferredMenu = true
        menus.clear()
        try check(!menus.active, "Space reset retained inferred menu state")
        for role in [kAXMenuRole, kAXMenuItemRole, kAXPopoverRole] {
            try check(DimmingMenuDetection.isMenu(role: role, transientApplication: false, layers: []),
                "AX menu/popover focus was treated as a missing document window")
        }
        let popup = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let floating = Int(CGWindowLevelForKey(.floatingWindow))
        try check(DimmingMenuDetection.isMenu(role: nil, transientApplication: false, layers: [popup]),
            "A native popup menu was not recognized")
        try check(DimmingMenuDetection.isMenu(role: nil, transientApplication: true, layers: [floating]),
            "An accessory application's transient panel was not recognized")
        for transient in [false, true] {
            try check(!DimmingMenuDetection.isMenu(role: nil, transientApplication: transient,
                layers: [Int(CGWindowLevelForKey(.statusWindow)), Int(CGWindowLevelForKey(.mainMenuWindow))]),
                "A permanent menu bar/status icon was mistaken for an open menu")
        }
        try check(!DimmingMenuDetection.isMenu(role: kAXWindowRole, transientApplication: false, layers: [floating]),
            "A regular application's floating window was mistaken for a menu")
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
