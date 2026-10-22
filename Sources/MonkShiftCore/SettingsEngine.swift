import Foundation

/// All snapshots are committed before any OS mutation. Failed restores remain retryable.
@MainActor public final class SettingsEngine {
    public private(set) var journal: RestoreJournal
    private let backend: SettingsBackend
    private let store: RestoreStore
    private var operationInProgress = false
    public var hasMonkSession: Bool { !journal.monk.isEmpty || journal.monkFocusBaseline != nil }
    public var hasIndividualChanges: Bool {
        !journal.individual.isEmpty || (!hasMonkSession && journal.stageManagerBeforeOneWindow != nil)
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
        var next = journal
        var affected = enabled ? [feature] + (feature.alternativeFocusMode.map { [$0] } ?? []) : [feature]
        if hasMonkSession && next.monkFocusBaseline == nil {
            next.monkFocusBaseline = .init(stageManagerBeforeOneWindow: journal.stageManagerBeforeOneWindow)
        }
        if feature == .oneWindowAtATime && enabled {
            _ = try await stageManagerState()
            affected.append(.stageManager)
            if next.stageManagerBeforeOneWindow == nil {
                next.stageManagerBeforeOneWindow = try await backend.snapshot(.stageManager)
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
                    if try await stageManagerState().enabled != true {
                        try await backend.apply(.stageManager, intensity: intensity)
                    }
                    try await requireStageManagerEnabled()
                }
                try await backend.disable(alternative)
                if feature == .dimBackground { try await restoreStageManagerAfterOneWindow() }
            }
            try await backend.apply(feature, intensity: intensity)
        } else if let snapshot = journal.monk[feature.rawValue] ?? journal.individual[feature.rawValue] {
            try await backend.restore(feature, from: snapshot)
            // A checkbox must turn the feature off even if it was already on before MonkShift.
            // Keep the original snapshot until Restore All so the exact baseline remains recoverable.
            if try await backend.read(feature).enabled == true { try await backend.disable(feature) }
            try await backend.finishChanges()
        } else {
            try await backend.disable(feature)
        }
        if feature == .oneWindowAtATime && !enabled { try await restoreStageManagerAfterOneWindow() }
    }

    private func stageManagerState() async throws -> FeatureState {
        let state = try await backend.read(.stageManager)
        guard state.available, state.enabled != nil else {
            throw MonkError(state.detail ?? "Stage Manager is unavailable or its state is unknown.")
        }
        return state
    }

    private func requireStageManagerEnabled() async throws {
        guard try await stageManagerState().enabled == true else {
            throw MonkError("Stage Manager could not be enabled. One-window mode was not changed.")
        }
    }

    private func restoreStageManagerAfterOneWindow() async throws {
        guard let snapshot = journal.stageManagerBeforeOneWindow else { return }
        try await backend.restore(.stageManager, from: snapshot)
        try await backend.finishChanges()
        var next = journal
        next.stageManagerBeforeOneWindow = nil
        try commit(next)
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
            next.monkFocusBaseline = .init(stageManagerBeforeOneWindow: journal.stageManagerBeforeOneWindow)
        }
        if selected == .oneWindowAtATime && next.stageManagerBeforeOneWindow == nil {
            do {
                guard next.monk[Feature.stageManager.rawValue] != nil else {
                    throw MonkError("Could not save Stage Manager. One-window mode was not changed.")
                }
                _ = try await stageManagerState()
                next.stageManagerBeforeOneWindow = try await backend.snapshot(.stageManager)
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
                        guard !issues.contains(where: { $0.feature == .stageManager || $0.feature == .oneWindowAtATime }) else {
                            throw MonkError("Stage Manager could not be enabled. One-window mode was not changed.")
                        }
                        try await requireStageManagerEnabled()
                    }
                    try await backend.disable(alternative)
                    if feature == .dimBackground { try await restoreStageManagerAfterOneWindow() }
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
                }
                try commit(next)
            } catch { issues.append(OperationIssue(feature, error)) }
        }
        if monk && journal.monk.isEmpty, let baseline = journal.monkFocusBaseline {
            var next = journal
            next.stageManagerBeforeOneWindow = baseline.stageManagerBeforeOneWindow
            next.monkFocusBaseline = nil
            do { try commit(next) }
            catch { issues.append(OperationIssue(.oneWindowAtATime, error)) }
        } else if !monk && journal.individual.isEmpty && !hasMonkSession {
            do { try await restoreStageManagerAfterOneWindow() }
            catch { issues.append(OperationIssue(.stageManager, error)) }
        }
        return issues
    }

    public func finishChanges() async throws {
        try beginOperation()
        defer { operationInProgress = false }
        try await backend.finishChanges()
    }
}
