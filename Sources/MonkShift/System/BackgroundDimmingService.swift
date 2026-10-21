import AppKit
import MonkShiftCore

struct DimmingTarget: Equatable, Sendable {
    let windowID: CGWindowID
    let bounds: CGRect
}

@MainActor protocol DimmingTracking: AnyObject {
    var onChange: ((DimmingTarget?) -> Void)? { get set }
    var onFocusChangeStarted: ((Bool) -> Void)? { get set }
    func start()
    func refresh()
    func stop()
}

@MainActor protocol DimmingRendering: AnyObject {
    func show(below target: DimmingTarget, intensity: Double) async throws
    func hide()
    func shutdown()
    func prepareForFocusChange()
}

extension DimmingRendering {
    func shutdown() { hide() }
    func prepareForFocusChange() {}
}

/// Owns only MonkShift's windows. No settings in another application are mutated.
@MainActor final class BackgroundDimmingService {
    struct State: Codable, Equatable {
        var enabled: Bool
        var intensity: Double
    }

    private(set) var state: State
    private(set) var detail: String?
    private let tracker: any DimmingTracking
    private let renderer: any DimmingRendering
    private let trusted: () -> Bool
    private let oneWindowEnabled: () async throws -> Bool
    private let save: (State) -> Void
    private var tracking = false
    private var target: DimmingTarget?
    private var revision = 0
    private var focusTransition: Task<Void, Never>?
    private var transitionID: UUID?
    private let transitionWait: () async throws -> Void

    init(state: State = State(enabled: false, intensity: 0.5), tracker: any DimmingTracking,
        renderer: any DimmingRendering, trusted: @escaping () -> Bool,
        oneWindowEnabled: @escaping () async throws -> Bool, save: @escaping (State) -> Void = { _ in },
        transitionWait: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(150)) }) {
        self.state = State(enabled: state.enabled, intensity: Self.clamp(state.intensity))
        self.tracker = tracker
        self.renderer = renderer
        self.trusted = trusted
        self.oneWindowEnabled = oneWindowEnabled
        self.save = save
        self.transitionWait = transitionWait
        tracker.onFocusChangeStarted = { [weak self] clearImmediately in
            guard let self else { return }
            if clearImmediately {
                self.cancelFocusTransition()
                self.revision += 1
                self.target = nil
                Task { @MainActor [weak self] in await self?.update() }
            } else { self.beginFocusTransition() }
        }
        tracker.onChange = { [weak self] target in
            guard let self else { return }
            // During activation AX can temporarily report no focused window. Keep
            // the existing layer until a replacement arrives or the deadline ends.
            if target == nil, self.transitionID != nil { return }
            self.cancelFocusTransition()
            self.target = target
            Task { @MainActor [weak self] in await self?.update() }
        }
    }

    static func clamp(_ intensity: Double) -> Double { intensity.isFinite ? min(0.9, max(0, intensity)) : 0.5 }

    func read() async -> FeatureState {
        await update()
        let allowed = trusted()
        return FeatureState(enabled: allowed ? state.enabled : false,
            detail: allowed ? detail : "Allow Accessibility to identify the active window. Other controls remain available.",
            available: allowed)
    }

    func set(enabled: Bool, intensity: Double? = nil) async throws {
        if enabled {
            guard trusted() else { throw MonkError("Allow Accessibility in System Settings to dim background windows.") }
            guard try await !oneWindowEnabled() else {
                throw MonkError("Turn off “Show windows one at a time” before enabling background dimming.")
            }
        }
        if let intensity {
            guard intensity.isFinite else { throw MonkError("Dimming intensity must be a finite number.") }
            state.intensity = Self.clamp(intensity)
        }
        state.enabled = enabled
        save(state)
        await update()
    }

    func restore(_ saved: State) async throws { try await set(enabled: saved.enabled, intensity: saved.intensity) }

    /// Exit hides the transient effect without changing the saved user preference.
    func shutdown() {
        cancelFocusTransition()
        revision += 1
        tracker.stop()
        tracking = false
        renderer.shutdown()
        target = nil
    }

    private func beginFocusTransition() {
        guard state.enabled, target != nil, transitionID == nil else { return }
        revision += 1
        renderer.prepareForFocusChange()
        let id = UUID()
        transitionID = id
        let wait = transitionWait
        focusTransition = Task { @MainActor [weak self] in
            do { try await wait() }
            catch { return }
            guard !Task.isCancelled, let self, transitionID == id else { return }
            transitionID = nil
            focusTransition = nil
            target = nil
            await update()
        }
    }

    private func cancelFocusTransition() {
        transitionID = nil
        focusTransition?.cancel()
        focusTransition = nil
    }

    private func update() async {
        revision += 1
        let currentRevision = revision
        guard state.enabled, trusted() else {
            shutdown()
            detail = nil
            return
        }
        do {
            let conflict = try await oneWindowEnabled()
            guard currentRevision == revision else { return }
            guard state.enabled, trusted() else { shutdown(); return }
            if !tracking { tracking = true; tracker.start() }
            if conflict {
                cancelFocusTransition()
                renderer.hide()
                detail = "Paused while “Show windows one at a time” is enabled."
            } else if state.intensity == 0 {
                cancelFocusTransition()
                renderer.hide()
                detail = "Intensity is 0%; increase it to dim the background."
            } else if transitionID != nil {
                detail = "Switching to the active window."
            } else if let target {
                try await renderer.show(below: target, intensity: state.intensity)
                guard currentRevision == revision else { return }
                detail = "Dims behind the active window. Stops when MonkShift quits."
            } else {
                renderer.hide()
                detail = "Paused until an active window can be identified."
            }
        } catch {
            guard currentRevision == revision else { return }
            renderer.hide()
            detail = "Dimming paused: \(error.localizedDescription)"
        }
    }
}

/// AppKit commits window ordering at a run-loop boundary. An immediate
/// on-screen list can omit a newly ordered window even when ordering succeeds.
enum DimmingOrderValidation {
    @MainActor static func validate(targetID: CGWindowID, overlayIDs: [CGWindowID],
        read: () -> [CGWindowID], wait: () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(40))
        }) async throws {
        var sawTarget = false
        for _ in 0..<3 {
            try await wait()
            try Task.checkCancellation()
            let ids = read()
            guard let targetIndex = ids.firstIndex(of: targetID) else { continue }
            sawTarget = true
            if !overlayIDs.isEmpty && overlayIDs.allSatisfy({ id in
                ids.firstIndex(of: id).map { $0 > targetIndex } ?? false
            }) { return }
        }
        throw MonkError(sawTarget ? "macOS did not place the dimming layer behind the active window." :
            "The active window is no longer visible.")
    }
}

/// One reusable, click-through window per display, with no animation or blur.
@MainActor final class DimmingOverlayRenderer: DimmingRendering {
    private var windows: [UInt32: DimmingPanel] = [:]
    private var lastTarget: DimmingTarget?
    private var lastIntensity: Double?
    private var revision = 0
    private var validation: Task<Void, Error>?

    func show(below target: DimmingTarget, intensity: Double) async throws {
        let screens = NSScreen.screens
        let screenIDs = Set(screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value })
        for id in Array(windows.keys) where !screenIDs.contains(id) { windows.removeValue(forKey: id)?.close() }
        var changed = lastTarget != target || lastIntensity != intensity
        for screen in screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            let panel: DimmingPanel
            if let existing = windows[id] { panel = existing }
            else {
                panel = DimmingPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
                panel.backgroundColor = .black
                panel.isOpaque = false
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.setAccessibilityElement(false)
                panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                panel.animationBehavior = .none
                panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .canJoinAllApplications]
                panel.level = .normal
                windows[id] = panel
                changed = true
            }
            if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false); changed = true }
            if panel.alphaValue != intensity { panel.alphaValue = intensity }
            if changed || !panel.isVisible { panel.order(.below, relativeTo: Int(target.windowID)) }
        }
        if !changed {
            if let validation { try await validation.value }
            return
        }
        revision += 1
        let currentRevision = revision
        validation?.cancel()
        lastTarget = target
        lastIntensity = intensity
        let overlayIDs = windows.values.map { CGWindowID($0.windowNumber) }
        let task = Task { @MainActor in
            try await DimmingOrderValidation.validate(targetID: target.windowID, overlayIDs: overlayIDs, read: {
                let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                return list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
            })
        }
        validation = task
        do {
            try await task.value
            if currentRevision == revision { validation = nil }
        } catch {
            // A result for an old target must never hide a newer target's layer.
            if currentRevision == revision { hide() }
            throw error
        }
    }

    func hide() {
        revision += 1
        validation?.cancel()
        validation = nil
        for panel in windows.values { panel.orderOut(nil) }
        lastTarget = nil
        lastIntensity = nil
    }

    func prepareForFocusChange() {
        // Cancel validation of the old anchor without ordering the layer out.
        revision += 1
        validation?.cancel()
        validation = nil
        lastTarget = nil
        lastIntensity = nil
    }

    func shutdown() {
        hide()
        for panel in windows.values { panel.close() }
        windows.removeAll()
        lastTarget = nil
        lastIntensity = nil
    }
}

@MainActor private final class DimmingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
