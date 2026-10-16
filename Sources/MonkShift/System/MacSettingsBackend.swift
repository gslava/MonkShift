import AppKit
import MonkShiftCore

@MainActor final class MacSettingsBackend: SettingsBackend {
    private let wallpaper: WallpaperService
    let colorFilter: Result<ColorFilterAPI, Error>
    private var dockNeedsReload = false
    private let dock = "com.apple.dock"
    private let windowManager = "com.apple.WindowManager"
    private let instantMenuMessage = "Unavailable: macOS has no verified system-wide control for this animation. Monk Mode applies the other settings."

    init(directory: URL) {
        wallpaper = WallpaperService(directory: directory)
        colorFilter = Result { try ColorFilterAPI() }
    }

    private func value(_ domain: String, _ key: String) -> Any? {
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    private func write(_ domain: String, _ key: String, _ value: Any?) throws {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw MonkError("macOS refused to save \(domain) → \(key).")
        }
        if domain == dock { dockNeedsReload = true }
    }
    private func keys(_ feature: Feature) -> (String, [String])? {
        switch feature {
        case .instantDock: return (dock, ["autohide-delay", "autohide-time-modifier"])
        case .stageManager: return (windowManager, ["GloballyEnabled"])
        case .hideRecentApps: return (windowManager, ["AutoHide"])
        case .oneWindowAtATime: return (windowManager, ["AppWindowGroupingBehavior"])
        default: return nil
        }
    }

    func read(_ feature: Feature) throws -> FeatureState {
        switch feature {
        case .instantDock:
            let keys = keys(feature)!
            let enabled = keys.1.allSatisfy { (value(keys.0, $0) as? NSNumber)?.doubleValue == 0 }
            return FeatureState(enabled: enabled)
        case .hideDock:
            return FeatureState(enabled: try SystemScript.run("get autohide of dock preferences").booleanValue)
        case .hideMenuBar:
            return FeatureState(enabled: try SystemScript.run("get autohide menu bar of dock preferences").booleanValue)
        case .instantMenuBar:
            return FeatureState(enabled: nil, detail: instantMenuMessage, available: false)
        case .stageManager:
            let ready = (value(dock, "workspaces-spans-displays") as? NSNumber)?.boolValue != true
            return FeatureState(enabled: (value(windowManager, "GloballyEnabled") as? NSNumber)?.boolValue ?? false,
                detail: ready ? nil : "Enable “Displays have separate Spaces” in System Settings, then log out and back in.", available: ready)
        case .hideRecentApps:
            return FeatureState(enabled: (value(windowManager, "AutoHide") as? NSNumber)?.boolValue ?? false,
                detail: "Takes effect while Stage Manager is on.")
        case .oneWindowAtATime:
            // 0 = All at Once; 1 = One at a Time. Missing preference defaults to All at Once.
            return FeatureState(enabled: (value(windowManager, "AppWindowGroupingBehavior") as? NSNumber)?.boolValue ?? false,
                detail: "Takes effect while Stage Manager is on.")
        case .blackWallpaper:
            return FeatureState(enabled: wallpaper.isBlack(), detail: "Connected displays in the current desktop Space.")
        case .grayscale:
            let state = try colorFilter.get().read()
            return FeatureState(enabled: state.enabled && state.type == 1)
        }
    }

    func snapshot(_ feature: Feature) throws -> Data {
        if let (domain, keys) = keys(feature) {
            // Absence is represented by a missing dictionary entry and restored by deleting that key.
            let values = keys.reduce(into: [String: Any]()) { if let v = value(domain, $1) { $0[$1] = v } }
            return try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        }
        switch feature {
        case .hideDock, .hideMenuBar: return try JSONEncoder().encode(try read(feature).enabled!)
        case .blackWallpaper: return try wallpaper.snapshot()
        case .grayscale: return try JSONEncoder().encode(colorFilter.get().read())
        default: throw MonkError(instantMenuMessage)
        }
    }

    func apply(_ feature: Feature, intensity: Double) throws {
        switch feature {
        case .instantDock:
            try write(dock, "autohide-delay", 0.0)
            try write(dock, "autohide-time-modifier", 0.0)
        case .hideDock: _ = try SystemScript.run("set autohide of dock preferences to true")
        case .hideMenuBar: _ = try SystemScript.run("set autohide menu bar of dock preferences to true")
        case .instantMenuBar: throw MonkError(instantMenuMessage)
        case .stageManager:
            guard try read(feature).available else { throw MonkError("Stage Manager requires “Displays have separate Spaces”.") }
            try write(windowManager, "GloballyEnabled", true)
        case .hideRecentApps: try write(windowManager, "AutoHide", true)
        case .oneWindowAtATime: try write(windowManager, "AppWindowGroupingBehavior", 1)
        case .blackWallpaper: try wallpaper.apply()
        case .grayscale: try colorFilter.get().apply(intensity: intensity)
        }
        guard try read(feature).enabled == true else { throw MonkError("macOS did not retain this setting. Its previous value is saved.") }
    }

    func disable(_ feature: Feature) throws {
        switch feature {
        case .instantDock:
            try write(dock, "autohide-delay", nil)
            try write(dock, "autohide-time-modifier", nil)
        case .hideDock: _ = try SystemScript.run("set autohide of dock preferences to false")
        case .hideMenuBar: _ = try SystemScript.run("set autohide menu bar of dock preferences to false")
        case .stageManager: try write(windowManager, "GloballyEnabled", false)
        case .hideRecentApps: try write(windowManager, "AutoHide", false)
        case .oneWindowAtATime: try write(windowManager, "AppWindowGroupingBehavior", 0)
        case .grayscale: try colorFilter.get().disable()
        case .blackWallpaper: throw MonkError("There is no saved wallpaper to restore. Choose a wallpaper in System Settings.")
        case .instantMenuBar: throw MonkError(instantMenuMessage)
        }
        guard try read(feature).enabled == false else { throw MonkError("macOS did not disable this setting.") }
    }

    func restore(_ feature: Feature, from data: Data) throws {
        if let (domain, keys) = keys(feature) {
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw MonkError("Invalid saved preference data. The restore file has been preserved.")
            }
            for key in keys {
                try write(domain, key, values[key])
                let observed = value(domain, key) as? NSObject
                let expected = values[key] as? NSObject
                guard observed == expected else { throw MonkError("macOS did not restore \(key).") }
            }
            return
        }
        switch feature {
        case .hideDock, .hideMenuBar:
            let enabled = try JSONDecoder().decode(Bool.self, from: data)
            let property = feature == .hideDock ? "autohide" : "autohide menu bar"
            _ = try SystemScript.run("set \(property) of dock preferences to \(enabled ? "true" : "false")")
            guard try read(feature).enabled == enabled else { throw MonkError("macOS did not restore \(feature.title).") }
        case .blackWallpaper: try wallpaper.restore(data)
        case .grayscale: try colorFilter.get().restore(JSONDecoder().decode(ColorFilterAPI.State.self, from: data))
        default: throw MonkError(instantMenuMessage)
        }
    }

    func finishChanges() throws {
        if dockNeedsReload {
            // A short-lived signal, no shell or resident helper. macOS relaunches Dock automatically.
            let docks = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            for application in docks {
                guard kill(application.processIdentifier, SIGTERM) == 0 || errno == ESRCH else {
                    throw MonkError("Could not reload Dock. Retry the operation or log out and back in.")
                }
            }
            dockNeedsReload = false
        }
    }
}
