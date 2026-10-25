import Foundation
import MonkShiftCore

private final class GroupingPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]
    private let ignoreWrites: Bool

    init(_ values: [String: Any], ignoreWrites: Bool = false) {
        self.values = values
        self.ignoreWrites = ignoreWrites
    }

    func contents() -> [String: Any] { lock.withLock { values } }

    func worker() -> PreferencesWorker {
        PreferencesWorker(readValue: { [self] domain, key in
            lock.withLock { domain == "com.apple.WindowManager" ? values[key] : nil }
        }, writeValue: { [self] domain, key, value in
            try require(domain == "com.apple.WindowManager", "Grouping changed another preference domain")
            lock.withLock { if !ignoreWrites { values[key] = value } }
        })
    }
}

@MainActor private final class GroupingBackend: SettingsBackend {
    let worker: PreferencesWorker
    private var dimming = false

    init(_ worker: PreferencesWorker) { self.worker = worker }

    func read(_ feature: Feature) async throws -> FeatureState {
        if feature == .dimBackground { return FeatureState(enabled: dimming) }
        return try await worker.read(feature)
    }

    func snapshot(_ feature: Feature) async throws -> Data {
        if feature == .dimBackground { return try JSONEncoder().encode(dimming) }
        return try await worker.snapshot(feature)
    }

    func apply(_ feature: Feature, intensity: Double) async throws {
        if feature == .dimBackground {
            try require(try await !worker.oneWindowModeIsActive(), "Dimming conflicts with active one-window mode")
            dimming = true
        } else { try await worker.apply(feature, intensity: intensity) }
    }

    func disable(_ feature: Feature) async throws {
        if feature == .dimBackground { dimming = false }
        else { try await worker.disable(feature) }
    }

    func restore(_ feature: Feature, from data: Data) async throws {
        if feature == .dimBackground { dimming = try JSONDecoder().decode(Bool.self, from: data) }
        else { try await worker.restore(feature, from: data) }
    }

    func finishChanges() async throws {}
}

enum WindowGroupingChecks {
    private static let key = "AppWindowGroupingBehavior"

    static func testObservedModes() async throws {
        // Raw values verified against WindowManager.AppWindowGroupingBehavior on macOS 15.8.1.
        for (raw, enabled) in [(0, true), (1, false), (2, true)] {
            let worker = GroupingPreferences([key: raw, "GloballyEnabled": true]).worker()
            try require(try await worker.read(.oneWindowAtATime).enabled == enabled,
                "Grouping value \(raw) was interpreted as the wrong mode")
        }
        for invalid: Any? in [nil, "0", 3, -1, 0.5] {
            let worker = GroupingPreferences(invalid.map { [key: $0, "GloballyEnabled": true] } ?? ["GloballyEnabled": true]).worker()
            let state = try await worker.read(.oneWindowAtATime)
            try require(state.enabled == nil && state.detail != nil,
                "Missing or unsupported grouping was silently interpreted as a known mode")
        }
    }

    static func testEnableAndDisable() async throws {
        let preferences = GroupingPreferences([key: 1, "GloballyEnabled": true, "AutoHide": true])
        let worker = preferences.worker()
        try await worker.apply(.oneWindowAtATime, intensity: 0.5)
        try require((preferences.contents()[key] as? NSNumber)?.intValue == 0,
            "Enabling one-window mode did not select the native single-window value")
        try require(try await worker.read(.oneWindowAtATime).enabled == true, "Enabled mode was read as off")
        try await worker.disable(.oneWindowAtATime)
        try require((preferences.contents()[key] as? NSNumber)?.intValue == 1,
            "Disabling one-window mode did not select all windows")
        try require(try await worker.read(.oneWindowAtATime).enabled == false, "Disabled mode was read as on")
        try require(preferences.contents()["GloballyEnabled"] as? Bool == true &&
            preferences.contents()["AutoHide"] as? Bool == true, "Grouping changed its prerequisites directly")
        try require(await !worker.needsDockReload(), "Grouping unnecessarily requested a Dock reload")
    }

    static func testRejectedWrites() async throws {
        for enable in [false, true] {
            let worker = GroupingPreferences([key: enable ? 1 : 0], ignoreWrites: true).worker()
            do {
                if enable { try await worker.apply(.oneWindowAtATime, intensity: 0.5) }
                else { try await worker.disable(.oneWindowAtATime) }
            } catch { continue }
            throw CheckFailure(description: "An ignored grouping write was reported as success")
        }
    }

    static func testExactRestoration() async throws {
        for original: Any? in [nil, 0, 1, 2, false, true] {
            let preferences = GroupingPreferences(original.map { [key: $0] } ?? [:])
            let worker = preferences.worker()
            let snapshot = try await worker.snapshot(.oneWindowAtATime)
            try await worker.apply(.oneWindowAtATime, intensity: 0.5)
            try await worker.restore(.oneWindowAtATime, from: snapshot)
            let restored = preferences.contents()[key] as? NSNumber
            if let original = original as? NSNumber {
                try require(restored == original && CFGetTypeID(restored!) == CFGetTypeID(original),
                    "Restoration changed the original grouping value or its type")
            } else { try require(restored == nil, "Restoration created an originally absent grouping key") }
        }
    }

    static func testActiveModeRequiresStageManager() async throws {
        for stage in [false, true] {
            for (raw, singleWindow) in [(0, true), (1, false), (2, true)] {
                let worker = GroupingPreferences([key: raw, "GloballyEnabled": stage]).worker()
                try require(try await worker.read(.oneWindowAtATime).enabled == (stage && singleWindow),
                    "One-window checkbox did not reflect whether Stage Manager was active")
                try require(try await worker.oneWindowModeIsActive() == (stage && singleWindow),
                    "Dimming conflict did not match the active Stage Manager mode")
            }
        }
        let missing = GroupingPreferences(["GloballyEnabled": false]).worker()
        try require(try await !missing.oneWindowModeIsActive(), "Disabled Stage Manager blocked dimming")
        let unknown = GroupingPreferences([key: 99, "GloballyEnabled": true]).worker()
        do { _ = try await unknown.oneWindowModeIsActive() }
        catch { return }
        throw CheckFailure(description: "Unknown active grouping was treated as safe for dimming")
    }

    @MainActor static func testFocusCycleAndRestoreAll() async throws {
        for original: Int? in [nil, 0, 1, 2] {
            for stage in [false, true] {
                for recent in [false, true] {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WindowGrouping-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: directory) }
                    var values: [String: Any] = ["GloballyEnabled": stage, "AutoHide": recent]
                    values[key] = original
                    let preferences = GroupingPreferences(values), worker = preferences.worker()
                    let backend = GroupingBackend(worker)
                    let engine = try SettingsEngine(backend: backend,
                        store: FileRestoreStore(url: directory.appendingPathComponent("restore.json")))
                    try await engine.set(.oneWindowAtATime, enabled: true, intensity: 0.5)
                    try require((preferences.contents()[key] as? NSNumber)?.intValue == 0,
                        "Focus cycle enabled the wrong native mode")
                    try await engine.set(.oneWindowAtATime, enabled: false, intensity: 0.5)
                    try require((preferences.contents()[key] as? NSNumber)?.intValue == 1,
                        "Turning the checkbox off restored an active or unknown one-window mode")
                    try require(preferences.contents()["GloballyEnabled"] as? Bool == false &&
                        preferences.contents()["AutoHide"] as? Bool == recent, "Focus exit left Stage Manager hiding other apps or lost recent-apps settings")
                    try await engine.set(.dimBackground, enabled: true, intensity: 0.5)
                    try require(try await backend.read(.dimBackground).enabled == true, "Dimming could not replace one-window mode")
                    try require(try await engine.restoreIndividual().isEmpty, "Original focus settings could not be restored")
                    try require((preferences.contents()[key] as? NSNumber)?.intValue == original,
                        "Restore All lost the exact original grouping or absence")
                    try require(preferences.contents()["GloballyEnabled"] as? Bool == stage &&
                        preferences.contents()["AutoHide"] as? Bool == recent, "Restore All lost the original Stage Manager/recent-apps settings")
                }
            }
        }
    }
}
