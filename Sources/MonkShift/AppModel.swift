import AppKit
import MonkShiftCore

@MainActor final class AppModel: ObservableObject {
    let permissions: PermissionManager
    let shortcuts: ShortcutManager
    @Published private(set) var states: [Feature: FeatureState] = [:]
    @Published private(set) var issues: [OperationIssue] = []
    @Published private(set) var generalError: String?
    @Published private(set) var busy = false
    @Published private(set) var hasSession = false
    @Published private(set) var hasIndividualChanges = false
    @Published var intensity: Double
    @Published private(set) var requestedValues: [Feature: Bool] = [:]
    @Published private(set) var requestedSession: Bool?
    var isEditingIntensity = false
    var onRefresh: (() -> Void)?
    private let backend: any ObservedSettingsBackend
    private let defaults: UserDefaults
    private var engine: SettingsEngine?
    @Published private(set) var refreshing = false
    private var storageError: String?
    private enum Change {
        case setting(Feature, Bool, Double)
        case monk(Bool, Double)
        case restoreAll
    }
    private var pendingChanges: [Change] = []
    private var settledRefresh: Task<Void, Never>?
    private var intensityRevision = 0
    private var quitRequested = false
    private var quitCompletion: (() -> Void)?
    var hasPendingChanges: Bool { !pendingChanges.isEmpty }

    /// Return true when AppKit must defer termination until accepted changes finish.
    func prepareToQuit(onReady: @escaping () -> Void) -> Bool {
        quitRequested = true
        settledRefresh?.cancel()
        guard busy || hasPendingChanges else { return false }
        if quitCompletion == nil { quitCompletion = onReady }
        return true
    }

    init(directory: URL, backend: (any ObservedSettingsBackend)? = nil,
        permissions: PermissionManager? = nil, shortcuts: ShortcutManager? = nil,
        defaults: UserDefaults = .standard) {
        self.permissions = permissions ?? PermissionManager()
        self.shortcuts = shortcuts ?? ShortcutManager()
        self.defaults = defaults
        intensity = defaults.object(forKey: "intensity") == nil ? 0.5 : min(1, max(0, defaults.double(forKey: "intensity")))
        self.backend = backend ?? MacSettingsBackend(directory: directory)
        do {
            engine = try SettingsEngine(backend: self.backend, store: FileRestoreStore(url: directory.appendingPathComponent("restore.json")))
        } catch {
            storageError = "Could not open the restore file. Settings changes are blocked to preserve it. \(error.localizedDescription)"
            generalError = storageError
        }
        updateJournalState()
        self.permissions.onUserCheckFinished = { [weak self] in self?.refresh() }
        self.shortcuts.onAction = { [weak self] action in
            guard let self else { return }
            if let feature = action.feature { self.toggle(feature) }
            else { self.toggleMonk() }
        }
    }

    // Availability is separate from transient work. Actions are serialized below.
    var canChange: Bool { permissions.granted && engine != nil }
    var canAdjustIntensity: Bool {
        canChange && states[.grayscale]?.available == true && states[.grayscale]?.enabled != nil
    }
    var canAdjustMenuIntensity: Bool { canAdjustIntensity && displayedEnabled(.grayscale) == true }

    var summary: FeatureSummary { FeatureSummary(states: states) }
    var displayedHasSession: Bool { requestedSession ?? hasSession }
    func displayedEnabled(_ feature: Feature) -> Bool? { requestedValues[feature] ?? states[feature]?.enabled }
    var statusTitle: String {
        if states.isEmpty && (refreshing || permissions.checking) { return "Checking settings…" }
        if !permissions.granted { return "Permission required" }
        return summary.title
    }
    var statusDetail: String {
        if states.isEmpty && (refreshing || permissions.checking) { return "Reading current macOS settings." }
        if !permissions.granted { return "Allow Automation to read the current settings." }
        return summary.detail
    }
    var statusNeedsAttention: Bool {
        generalError != nil || !issues.isEmpty
    }

    func refresh() {
        guard !quitRequested, !refreshing, !busy, !isEditingIntensity else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false; onRefresh?(); processChanges() }
            guard await permissions.refresh() else { shortcuts.deactivate(); states.removeAll(); return }
            shortcuts.activate()
            await readCurrentStates()
            updateJournalState()
        }
    }

    private func readCurrentStates() async {
        let previousIntensity = intensity
        let previousIntensityRevision = intensityRevision
        var current: [Feature: FeatureState] = [:]
        for feature in Feature.allCases {
            do { current[feature] = try await backend.read(feature) }
            catch { current[feature] = FeatureState(enabled: nil, detail: error.localizedDescription, available: false) }
        }
        states = current
        if current[.grayscale]?.enabled == true,
           let currentIntensity = try? await backend.intensity(),
           !isEditingIntensity, intensity == previousIntensity,
           intensityRevision == previousIntensityRevision, !hasQueuedIntensity {
            intensity = currentIntensity
        }
    }

    private var hasQueuedIntensity: Bool {
        pendingChanges.dropFirst(busy ? 1 : 0).contains {
            if case .setting(.grayscale, _, _) = $0 { return true }
            if case .monk(true, _) = $0 { return true }
            return false
        }
    }

    private func updateJournalState() {
        hasSession = engine?.hasMonkSession ?? false
        hasIndividualChanges = engine?.hasIndividualChanges ?? false
    }

    private func enqueue(_ change: Change) {
        guard canChange, !quitRequested else { return }
        settledRefresh?.cancel()
        pendingChanges.append(change)
        updateRequestedValues()
        onRefresh?()
        processChanges()
    }

    private func updateRequestedValues() {
        var values: [Feature: Bool] = [:]
        var session: Bool?
        for change in pendingChanges {
            switch change {
            case let .setting(feature, enabled, _): values[feature] = enabled
            case let .monk(enabled, _): session = enabled
            case .restoreAll: session = false
            }
        }
        requestedValues = values
        requestedSession = session
    }

    private func processChanges() {
        guard !busy, !refreshing, !pendingChanges.isEmpty, let engine else { return }
        generalError = storageError
        busy = true
        onRefresh?()
        Task { @MainActor in
            while !pendingChanges.isEmpty {
                // The first entry stays queued until read-back completes, so its
                // requested checkbox value never bounces back to the old value.
                let change = pendingChanges[0]
                guard await permissions.refresh() else {
                    shortcuts.deactivate()
                    states.removeAll()
                    pendingChanges.removeAll()
                    updateRequestedValues()
                    break
                }
                switch change {
                case let .setting(feature, _, _): issues.removeAll { $0.feature == feature }
                default: issues = []
                }
                do { issues += try await apply(change, using: engine) }
                catch { generalError = error.localizedDescription }
                do { try await engine.finishChanges() }
                catch { generalError = error.localizedDescription }
                await readCurrentStates()
                updateJournalState()
                pendingChanges.removeFirst()
                updateRequestedValues()
                onRefresh?()
            }
            busy = false
            onRefresh?()
            if let completion = quitCompletion {
                quitCompletion = nil
                completion()
                return
            }
            // One coalesced read after the entire queue, cancelled by a new action.
            settledRefresh = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(700)) }
                catch { return }
                self?.refresh()
            }
        }
    }

    private func apply(_ change: Change, using engine: SettingsEngine) async throws -> [OperationIssue] {
        switch change {
        case let .setting(feature, enabled, intensity):
            do { try await engine.set(feature, enabled: enabled, intensity: intensity); return [] }
            catch { return [OperationIssue(feature, error)] }
        case let .monk(enabled, intensity):
            if enabled { return try await engine.enableMonk(intensity: intensity) }
            return try await engine.restoreMonk()
        case .restoreAll:
            var issues = try await engine.restoreMonk()
            if !engine.hasMonkSession { issues += try await engine.restoreIndividual() }
            return issues
        }
    }

    func toggle(_ feature: Feature) {
        guard let enabled = displayedEnabled(feature) else { return }
        set(feature, enabled: !enabled)
    }

    func set(_ feature: Feature, enabled: Bool) {
        guard states[feature]?.available == true, states[feature]?.enabled != nil else { return }
        enqueue(.setting(feature, enabled, intensity))
    }

    func toggleMonk() {
        enqueue(.monk(!displayedHasSession, intensity))
    }

    func commitIntensity() {
        intensityRevision += 1
        defaults.set(intensity, forKey: "intensity")
        if displayedEnabled(.grayscale) == true { set(.grayscale, enabled: true) }
    }

    func restoreAll() {
        enqueue(.restoreAll)
    }

    func issue(for feature: Feature) -> String? { issues.first { $0.feature == feature }?.message }
    func showWallpaperSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!) }

#if MONKSHIFT_PREVIEW
    enum PreviewState: String, CaseIterable {
        case off, allEnabled, monkSession, partiallyEnabled, unknown, unavailable, failed, applying, refreshing
    }

    static func preview(directory: URL, state: PreviewState = .off) -> AppModel {
        let model = AppModel(directory: directory, shortcuts: ShortcutManager(installHandler: false))
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
        case .refreshing:
            model.refreshing = true
        }
        return model
    }
#endif
}
