import Foundation
import Darwin
import MonkShiftCore

/// Serializes potentially blocking preferences/filter work away from UI state.
actor PreferencesWorker {
    private let dock = "com.apple.dock"
    private let windowManager = "com.apple.WindowManager"
    private var dockNeedsReload = false
    private lazy var colorFilter = Result { try ColorFilterAPI() }

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
            return FeatureState(enabled: keys.1.allSatisfy { (value(keys.0, $0) as? NSNumber)?.doubleValue == 0 })
        case .stageManager:
            let ready = (value(dock, "workspaces-spans-displays") as? NSNumber)?.boolValue != true
            return FeatureState(enabled: (value(windowManager, "GloballyEnabled") as? NSNumber)?.boolValue ?? false,
                detail: ready ? nil : "Enable “Displays have separate Spaces” in System Settings, then log out and back in.", available: ready)
        case .hideRecentApps:
            return FeatureState(enabled: (value(windowManager, "AutoHide") as? NSNumber)?.boolValue ?? false,
                detail: "Takes effect while Stage Manager is on.")
        case .oneWindowAtATime:
            return FeatureState(enabled: (value(windowManager, "AppWindowGroupingBehavior") as? NSNumber)?.boolValue ?? false,
                detail: "Takes effect while Stage Manager is on.")
        case .grayscale:
            let state = try colorFilter.get().read()
            return FeatureState(enabled: state.enabled && state.type == 1)
        default: throw MonkError("\(feature.title) does not use the preferences backend.")
        }
    }

    func intensity() throws -> Double { try colorFilter.get().normalizedIntensity() }

    func snapshot(_ feature: Feature) throws -> Data {
        if let (domain, keys) = keys(feature) {
            let values = keys.reduce(into: [String: Any]()) { if let value = value(domain, $1) { $0[$1] = value } }
            return try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        }
        if feature == .grayscale { return try JSONEncoder().encode(colorFilter.get().read()) }
        throw MonkError("Could not capture preference keys for \(feature.title).")
    }

    func apply(_ feature: Feature, intensity: Double) throws {
        switch feature {
        case .instantDock:
            try write(dock, "autohide-delay", 0.0)
            try write(dock, "autohide-time-modifier", 0.0)
        case .stageManager:
            guard try read(feature).available else { throw MonkError("Stage Manager requires “Displays have separate Spaces”.") }
            try write(windowManager, "GloballyEnabled", true)
        case .hideRecentApps: try write(windowManager, "AutoHide", true)
        case .oneWindowAtATime: try write(windowManager, "AppWindowGroupingBehavior", 1)
        case .grayscale: try colorFilter.get().apply(intensity: intensity)
        default: throw MonkError("\(feature.title) does not use the preferences backend.")
        }
    }

    func disable(_ feature: Feature) throws {
        switch feature {
        case .instantDock:
            try write(dock, "autohide-delay", nil)
            try write(dock, "autohide-time-modifier", nil)
        case .stageManager: try write(windowManager, "GloballyEnabled", false)
        case .hideRecentApps: try write(windowManager, "AutoHide", false)
        case .oneWindowAtATime: try write(windowManager, "AppWindowGroupingBehavior", 0)
        case .grayscale: try colorFilter.get().disable()
        default: throw MonkError("\(feature.title) does not use the preferences backend.")
        }
    }

    func restore(_ feature: Feature, from data: Data) throws {
        if let (domain, keys) = keys(feature) {
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw MonkError("Invalid saved preference data. The restore file has been preserved.")
            }
            for key in keys {
                try write(domain, key, values[key])
                guard (value(domain, key) as? NSObject) == (values[key] as? NSObject) else {
                    throw MonkError("macOS did not restore \(key).")
                }
            }
        } else if feature == .grayscale {
            try colorFilter.get().restore(JSONDecoder().decode(ColorFilterAPI.State.self, from: data))
        } else { throw MonkError("Could not restore preference keys for \(feature.title).") }
    }

    func needsDockReload() -> Bool { dockNeedsReload }

    func reloadDock(processIDs: [pid_t]) throws {
        guard dockNeedsReload else { return }
        for pid in processIDs {
            guard kill(pid, SIGTERM) == 0 || errno == ESRCH else {
                throw MonkError("Could not reload Dock. Retry the operation or log out and back in.")
            }
        }
        dockNeedsReload = false
    }
}
