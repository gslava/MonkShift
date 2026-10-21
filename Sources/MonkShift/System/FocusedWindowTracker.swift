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
        let matches = windows.filter {
            $0.pid == pid && $0.layer == 0 && abs($0.bounds.minX - bounds.minX) < 2 &&
            abs($0.bounds.minY - bounds.minY) < 2 && abs($0.bounds.width - bounds.width) < 2 &&
            abs($0.bounds.height - bounds.height) < 2
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        return DimmingTarget(windowID: match.id, bounds: match.bounds)
    }
}

private struct FocusReading: @unchecked Sendable {
    let target: DimmingTarget?
    let element: AXUIElement?
}

/// AX calls may wait for another application's IPC. Bound them and keep them off AppKit.
private actor FocusReader {
    func read(pid: pid_t) -> FocusReading {
        guard AXIsProcessTrusted() else { return FocusReading(target: nil, element: nil) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return FocusReading(target: nil, element: nil)
        }
        let window = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.2)
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            return FocusReading(target: nil, element: window)
        }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return FocusReading(target: nil, element: window)
        }
        let windows = list.compactMap { info -> WindowMetadata? in
            guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value == pid,
                  let id = info[kCGWindowNumber as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let rect = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rect as CFDictionary) else { return nil }
            return WindowMetadata(id: id.uint32Value, pid: pid, layer: layer.intValue, bounds: bounds)
        }
        return FocusReading(target: WindowMetadata.focused(pid: pid,
            bounds: CGRect(origin: point, size: dimensions), windows: windows), element: window)
    }
}

/// Observes the frontmost app only. There is no timer, display link, or event tap.
@MainActor final class FocusedWindowTracker: DimmingTracking {
    var onChange: ((DimmingTarget?) -> Void)?
    var onFocusChangeStarted: ((Bool) -> Void)?
    private let reader = FocusReader()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var axApplication: AXUIElement?
    private var axWindow: AXUIElement?
    private var observedPID: pid_t?
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
                guard let app = NSWorkspace.shared.frontmostApplication else { onChange?(nil); break }
                guard attach(to: app.processIdentifier) else { onChange?(nil); break }
                let result = await reader.read(pid: app.processIdentifier)
                guard running, !Task.isCancelled else { break }
                guard revision == generation, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                    needsRefresh = true
                    continue
                }
                observe(window: result.element)
                onChange?(result.target)
            }
            if pendingID == id { pending = nil; pendingID = nil }
        }
    }

    func stop() {
        running = false
        generation += 1
        needsRefresh = false
        pending?.cancel()
        pending = nil
        pendingID = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        detach()
    }

    private func detach() {
        if let observer = axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        axObserver = nil
        axApplication = nil
        axWindow = nil
        observedPID = nil
    }

    private func attach(to pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if observedPID == pid { return true }
        detach()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            // This observer's source is installed only on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<FocusedWindowTracker>.fromOpaque(context).takeUnretainedValue().invalidateFocus()
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return false }
        axObserver = observer
        axApplication = app
        observedPID = pid
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, context) == .success else {
            // Without focus notifications an underlay could remain under the wrong
            // window indefinitely. Unsupported apps stay undimmed instead.
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
        return true
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
