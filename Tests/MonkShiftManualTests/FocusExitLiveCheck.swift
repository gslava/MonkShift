// Explicitly opted-in manual check. Never included in scripts/check.sh or CI.
import Foundation
import AppKit
import CoreGraphics
import MonkShiftCore

@MainActor private final class LiveFocusBackend: SettingsBackend {
    let worker = PreferencesWorker()
    func read(_ feature: Feature) async throws -> FeatureState {
        feature == .dimBackground ? FeatureState(enabled: false) : try await worker.read(feature)
    }
    func snapshot(_ feature: Feature) async throws -> Data {
        feature == .dimBackground ? try JSONEncoder().encode(false) : try await worker.snapshot(feature)
    }
    func apply(_ feature: Feature, intensity: Double) async throws {
        if feature != .dimBackground { try await worker.apply(feature, intensity: intensity) }
    }
    func disable(_ feature: Feature) async throws {
        if feature != .dimBackground { try await worker.disable(feature) }
    }
    func restore(_ feature: Feature, from data: Data) async throws {
        if feature != .dimBackground { try await worker.restore(feature, from: data) }
    }
    func finishChanges() async throws {}
}

@main enum FocusExitLiveCheck {
    private static let features: [Feature] = [.stageManager, .hideRecentApps, .oneWindowAtATime]

    @MainActor private static func visibleOwners() -> Set<pid_t> {
        let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? Int,
                  regular.contains(pid_t(pid)) else { return nil }
            return pid_t(pid)
        })
    }

    @MainActor private static func restore(_ baseline: [String: Data], using backend: LiveFocusBackend) async throws {
        var failures: [String] = []
        for feature in features {
            do {
                guard let snapshot = baseline[feature.rawValue] else { throw MonkError("Missing manual-check snapshot") }
                try await backend.restore(feature, from: snapshot)
            } catch { failures.append("\(feature.title): \(error.localizedDescription)") }
        }
        try await Task.sleep(for: .seconds(1))
        for feature in features {
            do {
                let original = try PropertyListSerialization.propertyList(from: baseline[feature.rawValue]!, format: nil) as! NSDictionary
                let current = try PropertyListSerialization.propertyList(from: await backend.snapshot(feature), format: nil) as! NSDictionary
                guard original == current else { throw MonkError("Original value was not restored") }
            } catch { failures.append("\(feature.title): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw MonkError(failures.joined(separator: "\n")) }
    }

    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3,
              ["--check", "--restore"].contains(CommandLine.arguments[1]) else {
            throw MonkError("Use scripts/check-focus-live.sh --allow-system-changes")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let baselineURL = directory.appendingPathComponent("initial-settings.plist")
        let backend = LiveFocusBackend()
        if CommandLine.arguments[1] == "--restore" {
            let baseline = try PropertyListSerialization.propertyList(from: Data(contentsOf: baselineURL), format: nil) as! [String: Data]
            try await restore(baseline, using: backend)
            print("Original focus settings restored exactly.")
            return
        }
        var baseline: [String: Data] = [:]
        for feature in features { baseline[feature.rawValue] = try await backend.snapshot(feature) }
        try PropertyListSerialization.data(fromPropertyList: baseline, format: .binary, options: 0).write(to: baselineURL, options: .atomic)
        var failure: Error?
        do {
            // Reproduce restart/legacy cycles using a private copy, never the app's journal.
            let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MonkShift/restore.json")
            let journalURL = directory.appendingPathComponent("restore.json")
            if FileManager.default.fileExists(atPath: source.path) {
                try Data(contentsOf: source).write(to: journalURL, options: .atomic)
            }
            let engine = try SettingsEngine(backend: backend, store: FileRestoreStore(url: journalURL))
            try await engine.set(.oneWindowAtATime, enabled: true, intensity: 0.5)
            try await Task.sleep(for: .seconds(1))
            let focused = visibleOwners()
            try await engine.set(.oneWindowAtATime, enabled: false, intensity: 0.5)
            try await Task.sleep(for: .seconds(1))
            guard try await backend.read(.stageManager).enabled == false,
                  try await backend.read(.oneWindowAtATime).enabled == false else {
                throw MonkError("Focus exit left Stage Manager or one-window mode enabled")
            }
            let normal = visibleOwners()
            print("Focus exit: Stage Manager off; one-window checkbox off.")
            print("Visible application owners: \(focused.count) during focus → \(normal.count) after exit.")
            guard !normal.subtracting(focused).isEmpty else {
                throw MonkError("No other app became visible. Open overlapping windows from at least two apps and retry; visual acceptance is not established.")
            }
        } catch { failure = error }
        try await restore(baseline, using: backend)
        print("Original focus settings restored exactly; the app's restore/profile files were not written.")
        if let failure { throw failure }
        print("PASS live focus exit reveals windows belonging to other apps.")
    }
}
