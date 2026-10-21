import AppKit
import ApplicationServices

struct WindowMetadata: Sendable {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let bounds: CGRect

    /// Never guess between same-sized windows belonging to the same process.
    static func focused(pid: pid_t, bounds: CGRect, windows: [WindowMetadata]) -> DimmingTarget? {
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let matches = windows.filter { $0.layer == 0 && $0.matches(pid: pid, bounds: bounds) }
        guard matches.count == 1, let match = matches.first else { return nil }
        return DimmingTarget(windowID: match.id, bounds: match.bounds)
    }

    func matches(pid: pid_t, bounds: CGRect) -> Bool {
        self.pid == pid && abs(self.bounds.minX - bounds.minX) < 2 &&
            abs(self.bounds.minY - bounds.minY) < 2 && abs(self.bounds.width - bounds.width) < 2 &&
            abs(self.bounds.height - bounds.height) < 2
    }
}

private struct FocusReading: @unchecked Sendable {
    let target: DimmingTarget?
    let element: AXUIElement?
    var menuActive = false
    var canRetainWindow = true
}

/// Menus can temporarily take AX focus without becoming the frontmost app.
/// Retain only an already identified, still-visible normal window. A different
/// regular application, an ambiguous new window or a Space reset must not reuse it.
struct DimmingFocusRetention {
    let pid: pid_t
    let target: DimmingTarget

    func visibleTarget(frontmostPID: pid_t, transientApplication: Bool, windows: [WindowMetadata]) -> DimmingTarget? {
        guard frontmostPID == pid || transientApplication,
            let window = windows.first(where: { $0.id == target.windowID && $0.pid == pid && $0.layer == 0 }),
            window.bounds.width > 1, window.bounds.height > 1 else { return nil }
        return DimmingTarget(windowID: window.id, bounds: window.bounds)
    }

    static func resolve(focused: DimmingTarget?, retained: DimmingTarget?, canRetainWindow: Bool, menuActive: Bool) -> DimmingTarget? {
        focused ?? ((canRetainWindow || menuActive) ? retained : nil)
    }

    static func isElevatedFocus(pid: pid_t, bounds: CGRect, windows: [WindowMetadata]) -> Bool {
        let matches = windows.filter { $0.matches(pid: pid, bounds: bounds) }
        return !matches.isEmpty && matches.allSatisfy { $0.layer != 0 }
    }
}

struct DimmingMenuState {
    var nativeMenus: Set<ObjectIdentifier> = []
    var accessibilityMenus: Set<CFHashCode> = []
    var inferredMenu = false
    var active: Bool { !nativeMenus.isEmpty || !accessibilityMenus.isEmpty || inferredMenu }
    mutating func clearExternal() { accessibilityMenus.removeAll(); inferredMenu = false }
    mutating func clear() { nativeMenus.removeAll(); clearExternal() }
}

/// Keeps confirmed window history separate from a transient AX reading.
struct DimmingFocusState {
    var anchor: DimmingFocusRetention?
    var menus = DimmingMenuState()

    mutating func completeReading(pid: pid_t, focused: DimmingTarget?, retained: DimmingTarget?,
        canRetainWindow: Bool, inferredMenu: Bool) -> DimmingTarget? {
        if let focused { anchor = DimmingFocusRetention(pid: pid, target: focused) }
        menus.inferredMenu = inferredMenu
        // A missing inferred menu must not override explicit native/AX tracking.
        // An unresolved read can pause rendering, but does not erase confirmed
        // history. The next preflight must validate that window before reusing it.
        return DimmingFocusRetention.resolve(focused: focused, retained: retained,
            canRetainWindow: canRetainWindow, menuActive: menus.active)
    }
}

enum DimmingMenuDetection {
    static func isMenu(role: String?, transientApplication: Bool, layers: [Int]) -> Bool {
        if let role, [kAXMenuRole, kAXMenuBarRole, kAXMenuBarItemRole, kAXMenuItemRole, kAXPopoverRole].contains(role) { return true }
        if layers.contains(Int(CGWindowLevelForKey(.popUpMenuWindow))) { return true }
        // Menu bar icons themselves are persistent status-level windows and must
        // never be mistaken for an open menu. Accessory popovers use panel levels.
        return transientApplication && layers.contains {
            $0 == Int(CGWindowLevelForKey(.floatingWindow)) || $0 == Int(CGWindowLevelForKey(.modalPanelWindow))
        }
    }
}

enum DimmingWindowClassification {
    static func isTransient(role: String?, subrole: String?, accessoryApplication: Bool, hasCloseButton: Bool) -> Bool {
        if DimmingMenuDetection.isMenu(role: role, transientApplication: false, layers: []) { return true }
        if let subrole, [kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole].contains(subrole) { return true }
        // Accessory utilities can implement their menu popups as ordinary titled
        // level-zero NSWindows. Require a close control before adopting one as a
        // new persistent window; their settings windows still qualify.
        return accessoryApplication && !hasCloseButton
    }
}

/// AX calls may wait for another application's IPC. Bound them and keep them off AppKit.
private actor FocusReader {
    func read(pid: pid_t, transientApplication: Bool) -> FocusReading {
        guard AXIsProcessTrusted() else { return FocusReading(target: nil, element: nil) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return missingFocus(app: app, pid: pid, window: nil, transientApplication: transientApplication)
        }
        let window = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.2)
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            return missingFocus(app: app, pid: pid, window: window, transientApplication: transientApplication)
        }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 1, dimensions.height > 1 else {
            return missingFocus(app: app, pid: pid, window: window, transientApplication: transientApplication)
        }
        let windows = windowList()
        let bounds = CGRect(origin: point, size: dimensions)
        if let target = WindowMetadata.focused(pid: pid, bounds: bounds, windows: windows) {
            if isTransientWindow(window, accessoryApplication: transientApplication) {
                return FocusReading(target: nil, element: window, menuActive: true)
            }
            return FocusReading(target: target, element: window)
        }
        var missing = missingFocus(app: app, pid: pid, window: window, transientApplication: transientApplication, windows: windows)
        // System menus/popovers can expose AXWindow at status/popup levels,
        // without AXMenu roles or menu notifications. Keep the document anchor;
        // ambiguous normal-level windows still fail closed.
        missing.canRetainWindow = DimmingFocusRetention.isElevatedFocus(pid: pid, bounds: bounds, windows: windows)
        return missing
    }

    private func isTransientWindow(_ window: AXUIElement, accessoryApplication: Bool) -> Bool {
        var role: CFTypeRef?, subrole: CFTypeRef?, closeButton: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        if accessoryApplication {
            AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButton)
        }
        return DimmingWindowClassification.isTransient(role: role as? String, subrole: subrole as? String,
            accessoryApplication: accessoryApplication,
            hasCloseButton: closeButton.map { CFGetTypeID($0) == AXUIElementGetTypeID() } ?? false)
    }

    func windowList() -> [WindowMetadata] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.compactMap { info -> WindowMetadata? in
            guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let id = info[kCGWindowNumber as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let rect = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rect as CFDictionary) else { return nil }
            return WindowMetadata(id: id.uint32Value, pid: owner.int32Value, layer: layer.intValue, bounds: bounds)
        }
        return windows
    }

    private func missingFocus(app: AXUIElement, pid: pid_t, window: AXUIElement?,
        transientApplication: Bool, windows: [WindowMetadata]? = nil) -> FocusReading {
        var focused: CFTypeRef?
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let element = focused as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.2)
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        }
        let windows = windows ?? windowList()
        return FocusReading(target: nil, element: window, menuActive: DimmingMenuDetection.isMenu(role: role as? String,
            transientApplication: transientApplication, layers: windows.filter { $0.pid == pid }.map(\.layer)))
    }
}

/// Observes one focus owner at a time, retaining its window during temporary
/// accessory/menu focus. There is no timer, display link, or event tap.
@MainActor final class FocusedWindowTracker: DimmingTracking {
    var onChange: ((DimmingTarget?) -> Void)?
    var onFocusChangeStarted: ((Bool) -> Void)?
    var onMenuTrackingChanged: ((Bool) -> Void)?
    private let reader = FocusReader()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var nativeMenuObservers: [NSObjectProtocol] = []
    private var focus = DimmingFocusState()
    private var reportedMenuTracking = false
    private var axObserver: AXObserver?
    private var axApplication: AXUIElement?
    private var axWindow: AXUIElement?
    private var anchorWindow: AXUIElement?
    private var observedPID: pid_t?
    private var observesFocus = false
    private var running = false
    private var generation = 0
    private var pending: Task<Void, Never>?
    private var pendingID: UUID?
    private var needsRefresh = false
    // Underlays follow the real window's shape and movement in WindowServer.
    // Observing move/resize would needlessly trigger AX and window-list IPC.
    private let windowNotifications = [kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]

    func start() {
        guard !running else { return }
        running = true
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            nativeMenuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let id = ObjectIdentifier(menu)
                let opening = notification.name == NSMenu.didBeginTrackingNotification
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    if opening { self.focus.menus.nativeMenus.insert(id) }
                    else { self.focus.menus.nativeMenus.remove(id) }
                    self.publishMenuTracking()
                    if !opening { self.refresh() }
                }
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.invalidateFocus() }
            })
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.invalidateFocus(clearImmediately: true) }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.invalidateFocus(clearImmediately: true) }
            }
        refresh()
    }

    private func invalidateFocus(clearImmediately: Bool = false) {
        generation += 1
        if clearImmediately { clearAnchor(); focus.menus.clear(); publishMenuTracking() }
        onFocusChangeStarted?(clearImmediately)
        refresh()
    }

    func refresh() {
        guard running else { return }
        needsRefresh = true
        guard pending == nil else { return }
        let id = UUID()
        pendingID = id
        pending = Task { @MainActor [weak self] in
            guard let self else { return }
            while running && needsRefresh && !Task.isCancelled {
                needsRefresh = false
                let revision = generation
                guard let app = NSWorkspace.shared.frontmostApplication else {
                    clearAnchor()
                    onFocusChangeStarted?(true)
                    onChange?(nil)
                    break
                }
                let pid = app.processIdentifier
                let transient = app.activationPolicy != .regular
                let windows = await reader.windowList()
                guard running, !Task.isCancelled else { break }
                guard revision == generation, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    needsRefresh = true
                    continue
                }
                if let anchor = focus.anchor,
                    anchor.visibleTarget(frontmostPID: anchor.pid, transientApplication: false, windows: windows) == nil {
                    clearAnchor()
                }
                let retained = focus.anchor?.visibleTarget(frontmostPID: pid, transientApplication: transient, windows: windows)
                // Resolve the visible anchor before any AX IPC. Menu tracking can
                // block the host's AX replies longer than the focus handoff deadline.
                if let retained { onChange?(retained) }
                if retained == nil || focus.anchor?.pid == pid {
                    let observing = attach(to: pid)
                    if observing, retained != nil { observe(window: anchorWindow) }
                }
                let result = await reader.read(pid: pid, transientApplication: transient)
                guard running, !Task.isCancelled else { break }
                guard revision == generation, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                    needsRefresh = true
                    continue
                }
                if result.target != nil, attach(to: pid) {
                    anchorWindow = result.element
                    observe(window: result.element)
                }
                // Keep the existing window observer when an accessory app/menu
                // takes focus, so closing/minimizing that anchor still clears it.
                let focused = observedPID == pid && observesFocus ? result.target : nil
                let resolved = focus.completeReading(pid: pid, focused: focused, retained: retained,
                    canRetainWindow: result.canRetainWindow, inferredMenu: result.menuActive)
                publishMenuTracking()
                onChange?(resolved)
            }
            if pendingID == id { pending = nil; pendingID = nil }
        }
    }

    func stop() {
        running = false
        generation += 1
        needsRefresh = false
        clearAnchor()
        pending?.cancel()
        pending = nil
        pendingID = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for observer in nativeMenuObservers { NotificationCenter.default.removeObserver(observer) }
        nativeMenuObservers.removeAll()
        focus.menus.clear()
        publishMenuTracking()
        detach()
    }

    private func publishMenuTracking() {
        guard focus.menus.active != reportedMenuTracking else { return }
        reportedMenuTracking = focus.menus.active
        onMenuTrackingChanged?(reportedMenuTracking)
    }

    private func clearAnchor() {
        focus.anchor = nil
        anchorWindow = nil
    }

    private func handle(notification: String, element: AXUIElement) {
        if [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification].contains(notification),
            let window = axWindow, CFEqual(window, element) {
            invalidateFocus(clearImmediately: true)
            return
        }
        if notification == kAXMenuOpenedNotification {
            focus.menus.accessibilityMenus.insert(CFHash(element))
            publishMenuTracking()
            refresh()
        } else if notification == kAXMenuClosedNotification {
            focus.menus.accessibilityMenus.remove(CFHash(element))
            focus.menus.inferredMenu = false
            publishMenuTracking()
            refresh()
        } else { invalidateFocus() }
    }

    private func detach() {
        if let observer = axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        axObserver = nil
        axApplication = nil
        axWindow = nil
        observedPID = nil
        observesFocus = false
        focus.menus.clearExternal()
        publishMenuTracking()
    }

    private func attach(to pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if observedPID == pid { return observesFocus }
        detach()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var observer: AXObserver?
        let callback: AXObserverCallback = { observer, element, notification, context in
            guard let context else { return }
            // This observer's source is installed only on the main run loop.
            MainActor.assumeIsolated {
                let tracker = Unmanaged<FocusedWindowTracker>.fromOpaque(context).takeUnretainedValue()
                guard tracker.running, let current = tracker.axObserver, CFEqual(observer, current) else { return }
                tracker.handle(notification: notification as String, element: element)
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return false }
        axObserver = observer
        axApplication = app
        observedPID = pid
        let context = Unmanaged.passUnretained(self).toOpaque()
        let focused = AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, context) == .success
        let focusedElement = AXObserverAddNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString, context) == .success
        let menuOpened = AXObserverAddNotification(observer, app, kAXMenuOpenedNotification as CFString, context) == .success
        let menuClosed = AXObserverAddNotification(observer, app, kAXMenuClosedNotification as CFString, context) == .success
        let observesMenus = menuOpened && menuClosed
        if menuOpened && !menuClosed {
            AXObserverRemoveNotification(observer, app, kAXMenuOpenedNotification as CFString)
        }
        observesFocus = focused || focusedElement
        guard observesFocus || observesMenus else {
            detach()
            return false
        }
        // Creating/reordering our decorative panels can produce main-window or
        // window-created notifications. Focus notifications already cover our UI;
        // observing our own panel lifecycle feeds overlay changes back into itself.
        if pid != getpid() {
            for name in [kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
                AXObserverAddNotification(observer, app, name as CFString, context)
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        // Menu-only observers can preserve an existing anchor, but cannot supply
        // a new one without reliable focus notifications.
        return observesFocus
    }

    private func observe(window: AXUIElement?) {
        guard let observer = axObserver else { return }
        if let previous = axWindow, let window, CFEqual(previous, window) { return }
        if let previous = axWindow {
            for name in windowNotifications { AXObserverRemoveNotification(observer, previous, name as CFString) }
        }
        axWindow = window
        guard let window else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in windowNotifications { AXObserverAddNotification(observer, window, name as CFString, context) }
    }
}
