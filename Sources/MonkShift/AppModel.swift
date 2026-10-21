import AppKit
import MonkShiftCore

@MainActor final class AppModel: ObservableObject {
    let permissions: PermissionManager
    let accessibility: AccessibilityPermissionManager
    let shortcuts: ShortcutManager
    @Published private(set) var states: [Feature: FeatureState] = [:]
    @Published private(set) var issues: [OperationIssue] = []
    @Published private(set) var generalError: String?
    @Published private(set) var busy = false
    @Published private(set) var hasSession = false
    @Published private(set) var hasIndividualChanges = false
    @Published var intensity: Double
    @Published var dimmingIntensity: Double
    @Published private(set) var preferredFocusMode: Feature
    @Published private(set) var requestedValues: [Feature: Bool] = [:]
    @Published private(set) var requestedSession: Bool?
    var isEditingIntensity = false
    var isEditingDimmingIntensity = false
    var onRefresh: (() -> Void)?
    private let backend: any ObservedSettingsBackend
    private let defaults: UserDefaults
    private var engine: SettingsEngine?
    @Published private(set) var refreshing = false
    private var storageError: String?
    private enum Change {
        case setting(Feature, Bool, Double)
        case monk(Bool, Double, Feature, Double)
        case restoreAll
    }
    private struct PendingChange {
        let change: Change
        let completion: ((Result<Void, Error>) -> Void)?
    }
    private var pendingChanges: [PendingChange] = []
    private var settledRefresh: Task<Void, Never>?
    private var intensityRevision = 0
    private var dimmingRevision = 0
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
        accessibility: AccessibilityPermissionManager? = nil,
        defaults: UserDefaults = .standard) {
        self.permissions = permissions ?? PermissionManager()
        let accessibility = accessibility ?? AccessibilityPermissionManager()
        self.accessibility = accessibility
        self.shortcuts = shortcuts ?? ShortcutManager()
        self.defaults = defaults
        intensity = defaults.object(forKey: "intensity") == nil ? 0.5 : min(1, max(0, defaults.double(forKey: "intensity")))
        dimmingIntensity = BackgroundDimmingService.clamp(defaults.object(forKey: "dimmingIntensity") == nil ? 0.5 : defaults.double(forKey: "dimmingIntensity"))
        preferredFocusMode = defaults.string(forKey: "preferredFocusMode") == Feature.dimBackground.rawValue ? .dimBackground : .oneWindowAtATime
        self.backend = backend ?? MacSettingsBackend(directory: directory, accessibility: accessibility, defaults: defaults)
        do {
            engine = try SettingsEngine(backend: self.backend, store: FileRestoreStore(url: directory.appendingPathComponent("restore.json")))
        } catch {
            storageError = "Could not open the restore file. Settings changes are blocked to preserve it. \(error.localizedDescription)"
            generalError = storageError
        }
        updateJournalState()
        self.permissions.onUserCheckFinished = { [weak self] in self?.refresh() }
        accessibility.onChange = { [weak self] in self?.onRefresh?() }
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
    var canAdjustDimmingIntensity: Bool {
        canChange && accessibility.granted && states[.dimBackground]?.available == true
    }
    var canAdjustMenuDimmingIntensity: Bool { canAdjustDimmingIntensity && displayedEnabled(.dimBackground) == true }

    var summary: FeatureSummary { FeatureSummary(states: states, focusMode: preferredFocusMode) }
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
        guard !quitRequested, !refreshing, !busy, !isEditingIntensity, !isEditingDimmingIntensity else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false; onRefresh?(); processChanges() }
            accessibility.refresh()
            guard await permissions.refresh() else { shortcuts.deactivate(); states.removeAll(); return }
            shortcuts.activate()
            await readCurrentStates()
            updateJournalState()
        }
    }

    private func readCurrentStates() async {
        let previousIntensity = intensity
        let previousIntensityRevision = intensityRevision
        let previousDimmingRevision = dimmingRevision
        let previousDimmingIntensity = dimmingIntensity
        var current: [Feature: FeatureState] = [:]
        for feature in Feature.allCases {
            do { current[feature] = try await backend.read(feature) }
            catch { current[feature] = FeatureState(enabled: nil, detail: error.localizedDescription, available: false) }
        }
        if !accessibility.granted {
            current[.dimBackground] = FeatureState(enabled: false,
                detail: "Allow Accessibility to dim background windows. Other controls remain available.", available: false)
        }
        states = current
        if current[.grayscale]?.enabled == true,
           let currentIntensity = try? await backend.intensity(),
           !isEditingIntensity, intensity == previousIntensity,
           intensityRevision == previousIntensityRevision, !hasQueuedIntensity {
            intensity = currentIntensity
        }
        let queuedDimming = pendingChanges.dropFirst(busy ? 1 : 0).contains {
            if case .setting(.dimBackground, _, _) = $0.change { return true }
            if case .monk(true, _, .dimBackground, _) = $0.change { return true }
            return false
        }
        if current[.dimBackground]?.enabled == true, !isEditingDimmingIntensity,
            dimmingRevision == previousDimmingRevision, dimmingIntensity == previousDimmingIntensity, !queuedDimming {
            dimmingIntensity = BackgroundDimmingService.clamp(backend.dimmingIntensity())
        }
    }

    private var hasQueuedIntensity: Bool {
        pendingChanges.dropFirst(busy ? 1 : 0).contains {
            if case .setting(.grayscale, _, _) = $0.change { return true }
            if case .monk(true, _, _, _) = $0.change { return true }
            return false
        }
    }

    private func updateJournalState() {
        hasSession = engine?.hasMonkSession ?? false
        hasIndividualChanges = engine?.hasIndividualChanges ?? false
    }

    private func enqueue(_ change: Change, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard canChange, !quitRequested else {
            completion?(.failure(MonkError(storageError ?? "Open MonkShift and grant Automation permission before running this action. If MonkShift is quitting, reopen it first.")))
            return
        }
        settledRefresh?.cancel()
        pendingChanges.append(PendingChange(change: change, completion: completion))
        updateRequestedValues()
        onRefresh?()
        processChanges()
    }

    private func updateRequestedValues() {
        var values: [Feature: Bool] = [:]
        var session: Bool?
        for pending in pendingChanges {
            switch pending.change {
            case let .setting(feature, enabled, _):
                values[feature] = enabled
                if enabled, let alternative = feature.alternativeFocusMode { values[alternative] = false }
            case let .monk(enabled, _, mode, _):
                session = enabled
                if enabled { values[mode] = true; if let alternative = mode.alternativeFocusMode { values[alternative] = false } }
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
                let pending = pendingChanges[0]
                let change = pending.change
                guard await permissions.refresh() else {
                    shortcuts.deactivate()
                    states.removeAll()
                    let cancelled = pendingChanges
                    pendingChanges.removeAll()
                    updateRequestedValues()
                    for pending in cancelled {
                        pending.completion?(.failure(MonkError("Open MonkShift and grant Automation permission, then run the shortcut again.")))
                    }
                    break
                }
                switch change {
                case let .setting(feature, _, _): issues.removeAll { $0.feature == feature }
                default: issues = []
                }
                var failure: Error?
                do {
                    let operationIssues = try await apply(change, using: engine)
                    issues += operationIssues
                    if !operationIssues.isEmpty {
                        failure = MonkError(operationIssues.map { "\($0.feature.title): \($0.message)" }.joined(separator: "\n"))
                    }
                } catch { generalError = error.localizedDescription; failure = error }
                do { try await engine.finishChanges() }
                catch { generalError = error.localizedDescription; failure = error }
                await readCurrentStates()
                updateJournalState()
                pendingChanges.removeFirst()
                updateRequestedValues()
                onRefresh?()
                if let failure { pending.completion?(.failure(failure)) }
                else { pending.completion?(.success(())) }
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
            do {
                if feature == .dimBackground, enabled, !accessibility.refresh() {
                    throw MonkError("Allow Accessibility in System Settings to dim background windows.")
                }
                try await engine.set(feature, enabled: enabled, intensity: intensity)
                return []
            }
            catch { return [OperationIssue(feature, error)] }
        case let .monk(enabled, intensity, mode, dimmingIntensity):
            if enabled { return try await engine.enableMonk(intensity: intensity, focusMode: mode, dimmingIntensity: dimmingIntensity) }
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
        guard canChange, !quitRequested, states[feature]?.available == true, states[feature]?.enabled != nil else { return }
        if enabled, feature.alternativeFocusMode != nil {
            preferredFocusMode = feature
            defaults.set(feature.rawValue, forKey: "preferredFocusMode")
        }
        enqueue(.setting(feature, enabled, feature == .dimBackground ? dimmingIntensity : intensity))
    }

    func toggleMonk() {
        enqueue(.monk(!displayedHasSession, intensity, preferredFocusMode, dimmingIntensity))
    }

    /// Return only after this command's mutation, persistence and read-back finish.
    func performMonkMode(_ command: MonkModeCommand) async throws {
        guard !quitRequested else { throw MonkError("MonkShift is quitting. Reopen it before running the shortcut.") }
        guard engine != nil else { throw MonkError(storageError ?? "The restore file is unavailable.") }
        guard await permissions.refresh() else {
            shortcuts.deactivate()
            states.removeAll()
            onRefresh?()
            throw MonkError("Open MonkShift and grant Automation permission, then run the shortcut again.")
        }
        try Task.checkCancellation()
        let enabled: Bool
        switch command {
        case .toggle: enabled = !displayedHasSession
        case .enable: enabled = true
        case .disable: enabled = false
        }
        try await withCheckedThrowingContinuation { continuation in
            enqueue(.monk(enabled, intensity, preferredFocusMode, dimmingIntensity)) { continuation.resume(with: $0) }
        }
    }

    func commitIntensity() {
        intensityRevision += 1
        defaults.set(intensity, forKey: "intensity")
        if displayedEnabled(.grayscale) == true { set(.grayscale, enabled: true) }
    }

    func commitDimmingIntensity() {
        dimmingIntensity = BackgroundDimmingService.clamp(dimmingIntensity)
        dimmingRevision += 1
        defaults.set(dimmingIntensity, forKey: "dimmingIntensity")
        if displayedEnabled(.dimBackground) == true { set(.dimBackground, enabled: true) }
    }

    func requestStartupPermissions() { accessibility.requestAtStartup(); refresh() }
    func shutdown() { backend.shutdown() }

    func restoreAll() {
        enqueue(.restoreAll)
    }

    func issue(for feature: Feature) -> String? { issues.first { $0.feature == feature }?.message }
    func showWallpaperSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!) }

#if MONKSHIFT_PREVIEW
    enum PreviewState: String, CaseIterable {
        case off, allEnabled, monkSession, dimming, dimmingDenied, partiallyEnabled, unknown, unavailable, failed, applying, refreshing
    }

    static func preview(directory: URL, state: PreviewState = .off) -> AppModel {
        let model = AppModel(directory: directory, shortcuts: ShortcutManager(installHandler: false))
        model.permissions.grantForPreview()
        model.accessibility.grantForPreview()
        for feature in Feature.allCases {
            model.states[feature] = FeatureState(enabled: false)
        }
        model.states[.hideRecentApps]?.detail = "Takes effect while Stage Manager is on."
        model.states[.oneWindowAtATime]?.detail = "Takes effect while Stage Manager is on."
        model.states[.blackWallpaper]?.detail = "Connected displays in the current desktop Space."
        switch state {
        case .off: break
        case .dimming, .dimmingDenied:
            model.preferredFocusMode = .dimBackground
            model.dimmingIntensity = 0.65
            model.states[.dimBackground]?.enabled = state == .dimming
            if state == .dimmingDenied {
                model.accessibility.denyForPreview()
                model.states[.dimBackground] = FeatureState(enabled: false,
                    detail: "Allow Accessibility to dim background windows. Other controls remain available.", available: false)
            }
        case .allEnabled, .monkSession, .unavailable, .failed:
            for feature in Feature.allCases { model.states[feature]?.enabled = true }
            model.states[.dimBackground]?.enabled = false
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
