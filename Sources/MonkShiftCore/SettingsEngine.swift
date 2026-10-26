import Foundation

/// All snapshots are committed before any OS mutation. Failed restores remain retryable.
@MainActor public final class SettingsEngine {
    public private(set) var journal: RestoreJournal
    private let backend: SettingsBackend
    private let store: RestoreStore
    private var operationInProgress = false
    public var hasMonkSession: Bool { !journal.monk.isEmpty || journal.monkFocusBaseline != nil }
    public var hasIndividualChanges: Bool {
        !journal.individual.isEmpty || (!hasMonkSession &&
            (journal.stageManagerBeforeOneWindow != nil || journal.hideRecentAppsBeforeOneWindow != nil))
    }

    public init(backend: SettingsBackend, store: RestoreStore) throws {
        self.backend = backend
        self.store = store
        self.journal = try store.load()
    }

    private func commit(_ candidate: RestoreJournal) throws {
        try store.save(candidate)
        journal = candidate
    }

    private func beginOperation() throws {
        guard !operationInProgress else { throw MonkError("A settings operation is already in progress. Try again when it finishes.") }
        operationInProgress = true
    }

    public func set(_ feature: Feature, enabled: Bool, intensity: Double) async throws {
        try beginOperation()
        defer { operationInProgress = false }
        try await setValue(feature, enabled: enabled, intensity: intensity)
    }

    private func setValue(_ feature: Feature, enabled: Bool, intensity: Double) async throws {
        var next = journal
        var affected = enabled ? [feature] + (feature.alternativeFocusMode.map { [$0] } ?? []) : [feature]
        // Leaving one-window focus must also reveal windows belonging to other
        // apps. Preserve Stage Manager before stopping it, even for an externally
        // enabled mode with no saved focus-cycle metadata.
        if (feature == .oneWindowAtATime && !enabled) || (feature == .dimBackground && enabled) {
            affected.append(.stageManager)
        }
        if hasMonkSession && next.monkFocusBaseline == nil {
            next.monkFocusBaseline = .init(stageManagerBeforeOneWindow: journal.stageManagerBeforeOneWindow,
                hideRecentAppsBeforeOneWindow: journal.hideRecentAppsBeforeOneWindow)
        }
        if feature == .oneWindowAtATime && enabled {
            _ = try await oneWindowPrerequisiteState(.stageManager)
            _ = try await oneWindowPrerequisiteState(.hideRecentApps)
            affected += [.stageManager, .hideRecentApps]
            if next.stageManagerBeforeOneWindow == nil {
                next.stageManagerBeforeOneWindow = try await backend.snapshot(.stageManager)
            }
            if next.hideRecentAppsBeforeOneWindow == nil {
                next.hideRecentAppsBeforeOneWindow = try await backend.snapshot(.hideRecentApps)
            }
        }
        for affectedFeature in affected where next.individual[affectedFeature.rawValue] == nil && next.monk[affectedFeature.rawValue] == nil {
            next.individual[affectedFeature.rawValue] = try await backend.snapshot(affectedFeature)
        }
        try commit(next)
        if enabled {
            if let alternative = feature.alternativeFocusMode {
                let status = try await backend.read(feature)
                guard status.available else { throw MonkError(status.detail ?? "This focus mode is unavailable.") }
                if feature == .oneWindowAtATime {
                    for prerequisite in [Feature.stageManager, .hideRecentApps] {
                        if try await oneWindowPrerequisiteState(prerequisite).enabled != true {
                            try await backend.apply(prerequisite, intensity: intensity)
                        }
                    }
                    try await requireOneWindowPrerequisites()
                }
                try await backend.disable(alternative)
                if feature == .dimBackground { try await restoreOneWindowPrerequisites(stoppingStageManager: true) }
            }
            try await backend.apply(feature, intensity: intensity)
        } else if let snapshot = journal.monk[feature.rawValue] ?? journal.individual[feature.rawValue] {
            try await backend.restore(feature, from: snapshot)
            // A checkbox must turn the feature off even if it was already on before MonkShift.
            // Keep the original snapshot until Restore All so the exact baseline remains recoverable.
            let restoredEnabled = try await backend.read(feature).enabled
            if feature == .oneWindowAtATime || restoredEnabled == true {
                try await backend.disable(feature)
            }
            try await backend.finishChanges()
        } else {
            try await backend.disable(feature)
        }
        if feature == .oneWindowAtATime && !enabled {
            try await restoreOneWindowPrerequisites(stoppingStageManager: true)
        }
    }

    public func applyProfile(_ settings: ProfileSettings) async throws -> [OperationIssue] {
        try settings.validate()
        try beginOperation()
        defer { operationInProgress = false }
        let settings = settings.normalized
        var next = journal
        var targets = settings.values
        if targets[.oneWindowAtATime] == true { targets[.dimBackground] = false }
        if targets[.dimBackground] == true { targets[.oneWindowAtATime] = false }
        // Focus transitions still need durable snapshots of settings they may
        // change, even when the profile leaves those dependencies disabled.
        let focusDependencies: Set<Feature> = targets[.oneWindowAtATime] == true ?
            [.stageManager, .hideRecentApps, .dimBackground] :
            targets[.dimBackground] == true ? [.stageManager, .oneWindowAtATime] : []
        // Capture the complete group before the first mutation, retaining any
        // earlier individual or Monk baseline across every profile switch.
        for feature in Feature.allCases where targets[feature] != nil {
            if targets[feature] == false && !focusDependencies.contains(feature) {
                let state = try? await backend.read(feature)
                if state?.available != true {
                    targets.removeValue(forKey: feature)
                    continue
                }
            }
            if next.individual[feature.rawValue] == nil && next.monk[feature.rawValue] == nil {
                next.individual[feature.rawValue] = try await backend.snapshot(feature)
            }
        }
        try commit(next)
        var issues: [OperationIssue] = []
        let focus: [Feature] = settings.values[.oneWindowAtATime] == true ? [.oneWindowAtATime] :
            settings.values[.dimBackground] == true ? [.dimBackground] : [.oneWindowAtATime, .dimBackground]
        let order = focus + Feature.allCases.filter { $0.alternativeFocusMode == nil }
        for feature in order {
            guard let enabled = targets[feature] else { continue }
            do {
                let state = try await backend.read(feature)
                // An unavailable disabled feature does not block other controls.
                if !enabled && !state.available { continue }
                guard state.available, let current = state.enabled else {
                    throw MonkError(state.detail ?? "This setting is unavailable or unknown.")
                }
                // Active focus modes also reconcile their dependencies. A saved
                // filter intensity must apply even if its checkbox is already on.
                if current != enabled || (enabled && (feature.alternativeFocusMode != nil || feature == .grayscale)) ||
                    (feature == .oneWindowAtATime && !enabled &&
                        (journal.stageManagerBeforeOneWindow != nil || journal.hideRecentAppsBeforeOneWindow != nil)) {
                    try await setValue(feature, enabled: enabled,
                        intensity: feature == .dimBackground ? settings.dimmingIntensity : settings.intensity)
                }
            } catch { issues.append(OperationIssue(feature, error)) }
        }
        return issues
    }

    private func oneWindowPrerequisiteState(_ feature: Feature) async throws -> FeatureState {
        let state = try await backend.read(feature)
        guard state.available, state.enabled != nil else {
            throw MonkError(state.detail ?? "\(feature.title) is unavailable or its state is unknown.")
        }
        return state
    }

    private func requireOneWindowPrerequisites() async throws {
        for feature in [Feature.stageManager, .hideRecentApps] {
            guard try await oneWindowPrerequisiteState(feature).enabled == true else {
                throw MonkError("\(feature.title) could not be enabled. One-window mode was not changed.")
            }
        }
    }

    private func restoreOneWindowPrerequisites(stoppingStageManager: Bool = false) async throws {
        for feature in [Feature.stageManager, .hideRecentApps] {
            let snapshot = feature == .stageManager ? journal.stageManagerBeforeOneWindow : journal.hideRecentAppsBeforeOneWindow
            if feature == .stageManager && stoppingStageManager {
                if try await backend.read(feature).enabled != false {
                    guard snapshot != nil || journal.individual[feature.rawValue] != nil || journal.monk[feature.rawValue] != nil else {
                        throw MonkError("Could not save Stage Manager before stopping it. Its current state was left unchanged.")
                    }
                    try await backend.disable(feature)
                }
                guard try await backend.read(feature).enabled == false else {
                    throw MonkError("Stage Manager is still enabled. Windows from other apps may remain hidden; retry turning off one-window mode.")
                }
            } else {
                guard let snapshot else { continue }
                try await backend.restore(feature, from: snapshot)
            }
            try await backend.finishChanges()
            // The original state remains in individual/Monk snapshots for
            // Restore All. Clear cycle metadata only after confirmed success.
            guard snapshot != nil else { continue }
            var next = journal
            if feature == .stageManager { next.stageManagerBeforeOneWindow = nil }
            else { next.hideRecentAppsBeforeOneWindow = nil }
            try commit(next)
        }
    }

    public func enableMonk(intensity: Double, focusMode: Feature = .oneWindowAtATime,
        dimmingIntensity: Double = 0.5) async throws -> [OperationIssue] {
        try beginOperation()
        defer { operationInProgress = false }
        var next = journal
        var issues: [OperationIssue] = []
        let selected = focusMode == .dimBackground ? Feature.dimBackground : .oneWindowAtATime
        for feature in Feature.allCases where next.monk[feature.rawValue] == nil {
            do {
                // The unselected mode still needs a baseline before it is disabled.
                // Capturing our own overlay state does not require Accessibility.
                if feature != selected.alternativeFocusMode {
                    let status = try await backend.read(feature)
                    guard status.available else { throw MonkError(status.detail ?? "Unavailable on this macOS version.") }
                }
                next.monk[feature.rawValue] = try await backend.snapshot(feature)
            } catch { issues.append(OperationIssue(feature, error)) }
        }
        if !next.monk.isEmpty && next.monkFocusBaseline == nil {
            next.monkFocusBaseline = .init(stageManagerBeforeOneWindow: journal.stageManagerBeforeOneWindow,
                hideRecentAppsBeforeOneWindow: journal.hideRecentAppsBeforeOneWindow)
        }
        if selected == .oneWindowAtATime {
            do {
                for feature in [Feature.stageManager, .hideRecentApps] {
                    guard next.monk[feature.rawValue] != nil else {
                        throw MonkError("Could not save \(feature.title). One-window mode was not changed.")
                    }
                    _ = try await oneWindowPrerequisiteState(feature)
                }
                if next.stageManagerBeforeOneWindow == nil {
                    next.stageManagerBeforeOneWindow = try await backend.snapshot(.stageManager)
                }
                if next.hideRecentAppsBeforeOneWindow == nil {
                    next.hideRecentAppsBeforeOneWindow = try await backend.snapshot(.hideRecentApps)
                }
            } catch { issues.append(OperationIssue(.oneWindowAtATime, error)) }
        }
        try commit(next)
        for feature in Feature.allCases where journal.monk[feature.rawValue] != nil {
            if feature == selected.alternativeFocusMode { continue }
            do {
                if let alternative = feature.alternativeFocusMode {
                    let status = try await backend.read(feature)
                    guard status.available else { throw MonkError(status.detail ?? "This focus mode is unavailable.") }
                    guard journal.monk[alternative.rawValue] != nil else {
                        throw MonkError("Could not save the other focus mode. Neither mode was changed.")
                    }
                    if feature == .oneWindowAtATime {
                        guard !issues.contains(where: { $0.feature == .stageManager || $0.feature == .hideRecentApps || $0.feature == .oneWindowAtATime }) else {
                            throw MonkError("Stage Manager and Hide recent apps must be enabled before one-window mode.")
                        }
                        try await requireOneWindowPrerequisites()
                    }
                    try await backend.disable(alternative)
                    if feature == .dimBackground { try await restoreOneWindowPrerequisites(stoppingStageManager: true) }
                }
                try await backend.apply(feature, intensity: feature == .dimBackground ? dimmingIntensity : intensity)
            }
            catch {
                if !issues.contains(where: { $0.feature == feature }) { issues.append(OperationIssue(feature, error)) }
            }
        }
        try await backend.finishChanges()
        return issues
    }

    public func restoreMonk() async throws -> [OperationIssue] {
        try beginOperation()
        defer { operationInProgress = false }
        return await restoreRecords(monk: true)
    }
    public func restoreIndividual() async throws -> [OperationIssue] {
        try beginOperation()
        defer { operationInProgress = false }
        return await restoreRecords(monk: false)
    }

    private func restoreRecords(monk: Bool) async -> [OperationIssue] {
        var issues: [OperationIssue] = []
        // Restore the system grouping preference before resuming an earlier overlay.
        let order = Feature.allCases.reversed().filter { $0.alternativeFocusMode == nil } + [.oneWindowAtATime, .dimBackground]
        for feature in order {
            guard let data = (monk ? journal.monk : journal.individual)[feature.rawValue] else { continue }
            do {
                try await backend.restore(feature, from: data)
                // Includes applying Dock reloads before declaring restoration complete.
                try await backend.finishChanges()
                var next = journal
                if monk { next.monk.removeValue(forKey: feature.rawValue) }
                else {
                    next.individual.removeValue(forKey: feature.rawValue)
                    if feature == .stageManager { next.stageManagerBeforeOneWindow = nil }
                    if feature == .hideRecentApps { next.hideRecentAppsBeforeOneWindow = nil }
                }
                try commit(next)
            } catch { issues.append(OperationIssue(feature, error)) }
        }
        if monk && journal.monk.isEmpty, let baseline = journal.monkFocusBaseline {
            var next = journal
            next.stageManagerBeforeOneWindow = baseline.stageManagerBeforeOneWindow
            next.hideRecentAppsBeforeOneWindow = baseline.hideRecentAppsBeforeOneWindow
            next.monkFocusBaseline = nil
            do { try commit(next) }
            catch { issues.append(OperationIssue(.oneWindowAtATime, error)) }
        } else if !monk && journal.individual.isEmpty && !hasMonkSession {
            do { try await restoreOneWindowPrerequisites() }
            catch { issues.append(OperationIssue(journal.stageManagerBeforeOneWindow != nil ? .stageManager : .hideRecentApps, error)) }
        }
        return issues
    }

    public func finishChanges() async throws {
        try beginOperation()
        defer { operationInProgress = false }
        try await backend.finishChanges()
    }
}
