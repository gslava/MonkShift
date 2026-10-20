import Foundation
import MonkShiftCore

/// All preference access stays in memory, including failures and ignored writes.
private final class DesktopPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]
    private var ignoredKey: String?
    private var journalURL: URL?
    private var writtenDomains: Set<String> = []

    init(_ values: [String: Any] = [:], journalURL: URL? = nil) {
        self.values = values
        self.journalURL = journalURL
    }

    func ignoreWrites(to key: String?) { lock.withLock { ignoredKey = key } }
    func contents() -> [String: Any] { lock.withLock { values } }
    func domains() -> Set<String> { lock.withLock { writtenDomains } }

    func worker() -> PreferencesWorker {
        PreferencesWorker(readValue: { [self] domain, key in
            lock.withLock { domain == "com.apple.WindowManager" ? values[key] : nil }
        }, writeValue: { [self] domain, key, value in
            try lock.withLock {
                if let journalURL {
                    let journal = try JSONDecoder().decode(RestoreJournal.self, from: Data(contentsOf: journalURL))
                    try require(journal.monk[Feature.hideDesktopItems.rawValue] != nil ||
                        journal.individual[Feature.hideDesktopItems.rawValue] != nil,
                        "Desktop preferences changed before their snapshot reached disk")
                }
                writtenDomains.insert(domain)
                if key != ignoredKey { values[key] = value }
            }
        })
    }
}

@MainActor private final class DesktopBackend: SettingsBackend {
    let preferences: PreferencesWorker
    init(_ preferences: PreferencesWorker) { self.preferences = preferences }

    func read(_ feature: Feature) async throws -> FeatureState {
        guard feature == .hideDesktopItems else { return FeatureState(enabled: nil, available: false) }
        return try await preferences.read(feature)
    }
    func snapshot(_ feature: Feature) async throws -> Data { try await preferences.snapshot(feature) }
    func apply(_ feature: Feature, intensity: Double) async throws { try await preferences.apply(feature, intensity: intensity) }
    func disable(_ feature: Feature) async throws { try await preferences.disable(feature) }
    func restore(_ feature: Feature, from data: Data) async throws { try await preferences.restore(feature, from: data) }
    func finishChanges() async throws {
        try require(await !preferences.needsDockReload(), "Desktop visibility unnecessarily restarted Dock")
    }
}

enum DesktopVisibilityChecks {
    private static let keys = ["StandardHideDesktopIcons", "HideDesktop", "StandardHideWidgets", "StageManagerHideWidgets"]

    private static func requireValues(_ actual: [String: Any], match expected: [String: Any]) throws {
        try require(Set(actual.keys) == Set(expected.keys), "Desktop restore changed which preference keys exist")
        for (key, original) in expected {
            guard let left = actual[key] as? NSNumber, let right = original as? NSNumber else {
                throw CheckFailure(description: "Unexpected preference value for \(key)")
            }
            try require(left == right && CFGetTypeID(left) == CFGetTypeID(right),
                "Desktop restore changed the original value or Boolean/integer type for \(key)")
        }
    }

    static func testObservedVisibility() async throws {
        for mask in 0..<16 {
            let values = Dictionary(uniqueKeysWithValues: keys.enumerated().map { index, key in
                let hidden = mask & (1 << index) != 0
                return (key, index.isMultiple(of: 2) ? NSNumber(value: hidden) : NSNumber(value: hidden ? 1 : 0))
            })
            let state = try await DesktopPreferences(values).worker().read(.hideDesktopItems)
            try require(state.enabled == (mask == 15) && state.available,
                "Partial desktop/Stage Manager visibility was reported as fully hidden")
            try require((state.detail != nil) == (mask != 0 && mask != 15), "Mixed desktop visibility was not explained")
        }
        let absent = try await DesktopPreferences().worker().read(.hideDesktopItems)
        try require(absent.enabled == false, "Missing desktop keys did not use macOS defaults")
        for invalid in ["unknown" as Any, 2, [1]] {
            let worker = DesktopPreferences([keys[3]: invalid]).worker()
            do {
                _ = try await worker.snapshot(.hideDesktopItems)
            } catch {
                try require(error.localizedDescription.contains("unknown desktop visibility"), "Unknown value lost its explanation")
                continue
            }
            throw CheckFailure(description: "An unknown desktop preference was accepted as a valid baseline")
        }
    }

    static func testExactPreferenceRestoration() async throws {
        let originals: [[String: Any]] = [[:], [keys[0]: true, keys[2]: 0],
            Dictionary(uniqueKeysWithValues: keys.map { ($0, 1) }),
            [keys[0]: false, keys[1]: 1, keys[2]: true, keys[3]: 0, "GloballyEnabled": true]]
        for original in originals {
            let fake = DesktopPreferences(original), worker = fake.worker()
            let snapshot = try await worker.snapshot(.hideDesktopItems)
            try await worker.apply(.hideDesktopItems, intensity: 0.5)
            try require(try await worker.read(.hideDesktopItems).enabled == true, "Desktop and Stage Manager were not both hidden")
            try await worker.restore(.hideDesktopItems, from: snapshot)
            try requireValues(fake.contents(), match: original)
            try require(fake.domains() == ["com.apple.WindowManager"], "Desktop changes wrote another preference domain")
            try require(await !worker.needsDockReload(), "Desktop changes requested a Dock reload")
        }
    }

    static func testDisableShowsBothModes() async throws {
        let fake = DesktopPreferences(Dictionary(uniqueKeysWithValues: keys.map { ($0, 1) }))
        let worker = fake.worker()
        try await worker.disable(.hideDesktopItems)
        for key in keys {
            try require((fake.contents()[key] as? NSNumber)?.intValue == 0, "Disabling did not show \(key)")
        }
        try require(try await worker.read(.hideDesktopItems).enabled == false, "Disabled visibility remained on")
    }

    static func testRejectedWrites() async throws {
        for hidden in [false, true] {
            for key in keys {
                let fake = DesktopPreferences(Dictionary(uniqueKeysWithValues: keys.map { ($0, hidden ? 0 : 1) }))
                fake.ignoreWrites(to: key)
                let worker = fake.worker()
                do {
                    if hidden { try await worker.apply(.hideDesktopItems, intensity: 0.5) }
                    else { try await worker.disable(.hideDesktopItems) }
                } catch {
                    try require(error.localizedDescription.contains(key), "Rejected desktop write did not identify the failed key")
                    continue
                }
                throw CheckFailure(description: "An ignored write for \(key) was reported as success")
            }
        }
    }

    @MainActor static func testSessionRestartRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopVisibility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("restore.json")
        let original: [String: Any] = [keys[0]: true, keys[2]: 0]
        let fake = DesktopPreferences(original, journalURL: url)
        let backend = DesktopBackend(fake.worker())
        let engine = try SettingsEngine(backend: backend, store: FileRestoreStore(url: url))
        let issues = try await engine.enableMonk(intensity: 0.5)
        try require(!issues.contains { $0.feature == .hideDesktopItems }, "Desktop visibility failed to join Monk Mode")
        let baseline = engine.journal.monk[Feature.hideDesktopItems.rawValue]
        _ = try await engine.enableMonk(intensity: 0.5)
        try require(engine.journal.monk[Feature.hideDesktopItems.rawValue] == baseline, "Repeated enable replaced the desktop baseline")
        fake.ignoreWrites(to: keys[3])
        let failures = try await engine.restoreMonk()
        try require(failures.map(\.feature) == [.hideDesktopItems], "Failed desktop restoration was not retained")
        let restarted = try SettingsEngine(backend: backend, store: FileRestoreStore(url: url))
        try require(restarted.journal.monk[Feature.hideDesktopItems.rawValue] == baseline, "Restart lost the original desktop values")
        fake.ignoreWrites(to: nil)
        try require(try await restarted.restoreMonk().isEmpty, "Desktop restoration could not be retried")
        try requireValues(fake.contents(), match: original)
        try require(!restarted.hasMonkSession, "Successful retry left an active session")
    }
}
