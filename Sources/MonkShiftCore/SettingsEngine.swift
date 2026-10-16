import Foundation

/// All snapshots are committed before any OS mutation. Failed restores remain retryable.
@MainActor public final class SettingsEngine {
    public private(set) var journal: RestoreJournal
    private let backend: SettingsBackend
    private let store: RestoreStore
    private var operationInProgress = false
    public var hasMonkSession: Bool { !journal.monk.isEmpty }
    public var hasIndividualChanges: Bool { !journal.individual.isEmpty }

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
        if journal.individual[feature.rawValue] == nil && journal.monk[feature.rawValue] == nil {
            var next = journal
            next.individual[feature.rawValue] = try await backend.snapshot(feature)
            try commit(next)
        }
        if enabled {
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
    }

    public func enableMonk(intensity: Double) async throws -> [OperationIssue] {
        try beginOperation()
        defer { operationInProgress = false }
        var next = journal
        var issues: [OperationIssue] = []
        for feature in Feature.allCases where next.monk[feature.rawValue] == nil {
            do {
                let status = try await backend.read(feature)
                guard status.available else { throw MonkError(status.detail ?? "Unavailable on this macOS version.") }
                next.monk[feature.rawValue] = try await backend.snapshot(feature)
            } catch { issues.append(OperationIssue(feature, error)) }
        }
        try commit(next)
        for feature in Feature.allCases where journal.monk[feature.rawValue] != nil {
            do { try await backend.apply(feature, intensity: intensity) }
            catch { issues.append(OperationIssue(feature, error)) }
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
        for feature in Feature.allCases.reversed() {
            guard let data = (monk ? journal.monk : journal.individual)[feature.rawValue] else { continue }
            do {
                try await backend.restore(feature, from: data)
                // Includes applying Dock reloads before declaring restoration complete.
                try await backend.finishChanges()
                var next = journal
                if monk { next.monk.removeValue(forKey: feature.rawValue) }
                else { next.individual.removeValue(forKey: feature.rawValue) }
                try commit(next)
            } catch { issues.append(OperationIssue(feature, error)) }
        }
        return issues
    }

    public func finishChanges() async throws {
        try beginOperation()
        defer { operationInProgress = false }
        try await backend.finishChanges()
    }
}
