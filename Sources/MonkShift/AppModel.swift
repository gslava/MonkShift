import AppKit
import MonkShiftCore

@MainActor final class AppModel: ObservableObject {
    let permissions = PermissionManager()
    let shortcuts = ShortcutManager()
    @Published private(set) var states: [Feature: FeatureState] = [:]
    @Published private(set) var issues: [OperationIssue] = []
    @Published private(set) var generalError: String?
    @Published private(set) var busy = false
    @Published private(set) var hasSession = false
    @Published private(set) var hasIndividualChanges = false
    @Published var intensity: Double
    var isEditingIntensity = false
    var onRefresh: (() -> Void)?
    private let backend: MacSettingsBackend
    private var engine: SettingsEngine?
    @Published private(set) var refreshing = false
    private var storageError: String?

    init(directory: URL) {
        let defaults = UserDefaults.standard
        intensity = defaults.object(forKey: "intensity") == nil ? 0.5 : min(1, max(0, defaults.double(forKey: "intensity")))
        backend = MacSettingsBackend(directory: directory)
        do {
            engine = try SettingsEngine(backend: backend, store: FileRestoreStore(url: directory.appendingPathComponent("restore.json")))
        } catch {
            storageError = "Could not open the restore file. Settings changes are blocked to preserve it. \(error.localizedDescription)"
            generalError = storageError
        }
        updateJournalState()
        permissions.onUserCheckFinished = { [weak self] in self?.refresh() }
        shortcuts.onAction = { [weak self] action in
            guard let self else { return }
            if let feature = action.feature { self.toggle(feature) }
            else { self.toggleMonk() }
        }
    }

    var canChange: Bool { permissions.granted && !permissions.checking && !busy && !refreshing && engine != nil }
    var canAdjustIntensity: Bool {
        canChange && states[.grayscale]?.available == true && states[.grayscale]?.enabled != nil
    }
    var canAdjustMenuIntensity: Bool { canAdjustIntensity && states[.grayscale]?.enabled == true }

    var summary: FeatureSummary { FeatureSummary(states: states) }
    var statusTitle: String {
        if busy { return "Applying settings…" }
        if refreshing || permissions.checking { return "Checking settings…" }
        if !permissions.granted { return "Permission required" }
        return summary.title
    }
    var statusDetail: String {
        if busy { return "The current operation is still in progress." }
        if refreshing || permissions.checking { return "Reading current macOS settings." }
        if !permissions.granted { return "Allow Automation to read the current settings." }
        return summary.detail
    }
    var statusNeedsAttention: Bool {
        generalError != nil || !issues.isEmpty
    }

    func refresh() {
        guard !refreshing, !busy, !isEditingIntensity else { return }
        refreshing = true
        onRefresh?()
        Task { @MainActor in
            defer { refreshing = false; onRefresh?() }
            guard await permissions.refresh() else { shortcuts.deactivate(); states.removeAll(); return }
            guard !busy else { return }
            shortcuts.activate()
            var current: [Feature: FeatureState] = [:]
            for feature in Feature.allCases {
                do { current[feature] = try await backend.read(feature) }
                catch { current[feature] = FeatureState(enabled: nil, detail: error.localizedDescription, available: false) }
            }
            states = current
            if current[.grayscale]?.enabled == true, !isEditingIntensity,
               let currentIntensity = try? await backend.intensity() {
                intensity = currentIntensity
            }
            updateJournalState()
        }
    }

    private func updateJournalState() {
        hasSession = engine?.hasMonkSession ?? false
        hasIndividualChanges = engine?.hasIndividualChanges ?? false
    }

    private func perform(_ operation: @escaping @MainActor (SettingsEngine) async throws -> [OperationIssue]) {
        // Every entry point, including shortcuts and menu actions, rechecks permissions.
        guard !busy, !refreshing, let engine else { return }
        busy = true
        generalError = storageError
        issues = []
        onRefresh?()
        // Publish progress before starting the asynchronous system operation.
        Task { @MainActor in
            await Task.yield()
            guard await self.permissions.refresh() else {
                self.shortcuts.deactivate()
                self.busy = false
                self.refresh()
                return
            }
            do { self.issues = try await operation(engine) }
            catch { self.generalError = error.localizedDescription }
            do { try await engine.finishChanges() }
            catch { self.generalError = error.localizedDescription }
            self.busy = false
            self.updateJournalState()
            self.refresh()
            // One delayed read after macOS has processed changes; no repeating polling.
            try? await Task.sleep(for: .milliseconds(700))
            self.refresh()
        }
    }

    func toggle(_ feature: Feature) {
        perform { engine in
            let state = try await self.backend.read(feature)
            guard state.available, let enabled = state.enabled else { return [] }
            do { try await engine.set(feature, enabled: !enabled, intensity: self.intensity); return [] }
            catch { return [OperationIssue(feature, error)] }
        }
    }

    func set(_ feature: Feature, enabled: Bool) {
        perform { engine in
            do { try await engine.set(feature, enabled: enabled, intensity: self.intensity); return [] }
            catch { return [OperationIssue(feature, error)] }
        }
    }

    func toggleMonk() {
        perform { engine in
            if engine.hasMonkSession { return try await engine.restoreMonk() }
            return try await engine.enableMonk(intensity: self.intensity)
        }
    }

    func commitIntensity() {
        UserDefaults.standard.set(intensity, forKey: "intensity")
        if states[.grayscale]?.enabled == true { set(.grayscale, enabled: true) }
    }

    func restoreAll() {
        perform { engine in
            var issues = try await engine.restoreMonk()
            // Preserve ordering: individual settings may predate the Monk session.
            if !engine.hasMonkSession { issues += try await engine.restoreIndividual() }
            return issues
        }
    }

    func issue(for feature: Feature) -> String? { issues.first { $0.feature == feature }?.message }
    func showWallpaperSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!) }

#if MONKSHIFT_PREVIEW
    enum PreviewState: String, CaseIterable {
        case off, allEnabled, monkSession, partiallyEnabled, unknown, unavailable, failed, applying
    }

    static func preview(directory: URL, state: PreviewState = .off) -> AppModel {
        let model = AppModel(directory: directory)
        model.permissions.grantForPreview()
        for feature in Feature.allCases {
            model.states[feature] = FeatureState(enabled: false)
        }
        model.states[.hideRecentApps]?.detail = "Takes effect while Stage Manager is on."
        model.states[.oneWindowAtATime]?.detail = "Takes effect while Stage Manager is on."
        model.states[.blackWallpaper]?.detail = "Connected displays in the current desktop Space."
        switch state {
        case .off: break
        case .allEnabled, .monkSession, .unavailable, .failed:
            for feature in Feature.allCases { model.states[feature]?.enabled = true }
            // An all-enabled state does not require a saved Monk Mode session.
            if state == .monkSession { model.hasSession = true }
            if state == .unavailable {
                model.states[.stageManager] = FeatureState(enabled: nil,
                    detail: "Enable “Displays have separate Spaces” in System Settings, then log out and back in.", available: false)
            }
            if state == .failed {
                model.generalError = "Could not save restoration progress. The saved settings are retained for retry."
                model.hasSession = true
            }
        case .partiallyEnabled:
            model.states[.hideDock]?.enabled = true
            model.states[.grayscale]?.enabled = true
            model.hasSession = true
        case .unknown:
            model.states[.grayscale] = FeatureState(enabled: nil, detail: "Could not read the current color filter state.")
        case .applying:
            model.busy = true
        }
        return model
    }
#endif
}
