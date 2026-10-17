import AppKit
import MonkShiftCore

@MainActor protocol ObservedSettingsBackend: SettingsBackend {
    func intensity() async throws -> Double
}

@MainActor final class MacSettingsBackend: ObservedSettingsBackend {
    private let wallpaper: WallpaperService
    private let preferences = PreferencesWorker()
    private let events = SystemEventsClient()

    init(directory: URL) { wallpaper = WallpaperService(directory: directory) }

    func read(_ feature: Feature) async throws -> FeatureState {
        switch feature {
        case .hideDock: return FeatureState(enabled: try await events.read(.hideDock))
        case .hideMenuBar: return FeatureState(enabled: try await events.read(.hideMenuBar))
        case .blackWallpaper:
            return FeatureState(enabled: wallpaper.isBlack(), detail: "Connected displays in the current desktop Space.")
        default: return try await preferences.read(feature)
        }
    }

    func intensity() async throws -> Double { try await preferences.intensity() }

    func snapshot(_ feature: Feature) async throws -> Data {
        switch feature {
        case .hideDock, .hideMenuBar:
            guard let enabled = try await read(feature).enabled else { throw MonkError("Could not read \(feature.title).") }
            return try JSONEncoder().encode(enabled)
        case .blackWallpaper: return try wallpaper.snapshot()
        default: return try await preferences.snapshot(feature)
        }
    }

    func apply(_ feature: Feature, intensity: Double) async throws {
        switch feature {
        case .hideDock: try await events.write(.hideDock, enabled: true)
        case .hideMenuBar: try await events.write(.hideMenuBar, enabled: true)
        case .blackWallpaper: try wallpaper.apply()
        default: try await preferences.apply(feature, intensity: intensity)
        }
        guard try await read(feature).enabled == true else {
            throw MonkError("macOS did not retain this setting. Its previous value is saved.")
        }
    }

    func disable(_ feature: Feature) async throws {
        switch feature {
        case .hideDock: try await events.write(.hideDock, enabled: false)
        case .hideMenuBar: try await events.write(.hideMenuBar, enabled: false)
        case .blackWallpaper: throw MonkError("There is no saved wallpaper to restore. Choose a wallpaper in System Settings.")
        default: try await preferences.disable(feature)
        }
        guard try await read(feature).enabled == false else { throw MonkError("macOS did not disable this setting.") }
    }

    func restore(_ feature: Feature, from data: Data) async throws {
        switch feature {
        case .hideDock, .hideMenuBar:
            let enabled = try JSONDecoder().decode(Bool.self, from: data)
            try await events.write(feature == .hideDock ? .hideDock : .hideMenuBar, enabled: enabled)
            guard try await read(feature).enabled == enabled else { throw MonkError("macOS did not restore \(feature.title).") }
        case .blackWallpaper: try wallpaper.restore(data)
        default: try await preferences.restore(feature, from: data)
        }
    }

    func finishChanges() async throws {
        guard await preferences.needsDockReload() else { return }
        let processes = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .map(\.processIdentifier)
        try await preferences.reloadDock(processIDs: processes)
    }
}
