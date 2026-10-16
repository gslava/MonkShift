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
    private(set) var refreshing = false
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

    var canChange: Bool { permissions.granted && !permissions.checking && !busy && engine != nil }

    func refresh() {
        guard !refreshing, !busy else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false; onRefresh?() }
            guard await permissions.refresh() else { shortcuts.deactivate(); states.removeAll(); return }
            guard !busy else { return }
            shortcuts.activate()
            var current: [Feature: FeatureState] = [:]
            for feature in Feature.allCases {
                do { current[feature] = try backend.read(feature) }
                catch { current[feature] = FeatureState(enabled: nil, detail: error.localizedDescription, available: false) }
            }
            states = current
            if current[.grayscale]?.enabled == true, !isEditingIntensity,
               let api = try? backend.colorFilter.get() {
                intensity = api.normalizedIntensity()
            }
            updateJournalState()
        }
    }

    private func updateJournalState() {
        hasSession = engine?.hasMonkSession ?? false
        hasIndividualChanges = engine?.hasIndividualChanges ?? false
    }

    private func perform(_ operation: @escaping (SettingsEngine) throws -> [OperationIssue]) {
        // Every entry point, including shortcuts and menu actions, rechecks permissions.
        guard !busy, let engine else { return }
        busy = true
        generalError = storageError
        issues = []
        // Yield one frame so native controls show progress before synchronous system APIs run.
        Task { @MainActor in
            await Task.yield()
            guard await self.permissions.refresh() else {
                self.shortcuts.deactivate()
                self.busy = false
                self.refresh()
                return
            }
            do { self.issues = try operation(engine) }
            catch { self.generalError = error.localizedDescription }
            do { try engine.finishChanges() }
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
            let state = try self.backend.read(feature)
            guard state.available, let enabled = state.enabled else { return [] }
            do { try engine.set(feature, enabled: !enabled, intensity: self.intensity); return [] }
            catch { return [OperationIssue(feature, error)] }
        }
    }

    func set(_ feature: Feature, enabled: Bool) {
        perform { engine in
            do { try engine.set(feature, enabled: enabled, intensity: self.intensity); return [] }
            catch { return [OperationIssue(feature, error)] }
        }
    }

    func toggleMonk() {
        perform { engine in
            engine.hasMonkSession ? engine.restoreMonk() : try engine.enableMonk(intensity: self.intensity)
        }
    }

    func commitIntensity() {
        UserDefaults.standard.set(intensity, forKey: "intensity")
        if states[.grayscale]?.enabled == true { set(.grayscale, enabled: true) }
    }

    func restoreAll() {
        perform { engine in
            var issues = engine.restoreMonk()
            // Preserve ordering: individual settings may predate the Monk session.
            if !engine.hasMonkSession { issues += engine.restoreIndividual() }
            return issues
        }
    }

    func issue(for feature: Feature) -> String? { issues.first { $0.feature == feature }?.message }
    func showWallpaperSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!) }

#if MONKSHIFT_PREVIEW
    static func preview(directory: URL) -> AppModel {
        let model = AppModel(directory: directory)
        model.permissions.grantForPreview()
        for feature in Feature.allCases {
            model.states[feature] = FeatureState(enabled: false)
        }
        model.states[.instantMenuBar] = FeatureState(enabled: nil,
            detail: "Unavailable: macOS has no verified system-wide control for this animation. Monk Mode applies the other settings.", available: false)
        model.states[.hideRecentApps]?.detail = "Takes effect while Stage Manager is on."
        model.states[.oneWindowAtATime]?.detail = "Takes effect while Stage Manager is on."
        model.states[.blackWallpaper]?.detail = "Connected displays in the current desktop Space."
        return model
    }
#endif
}
