import Foundation
import Darwin
import MonkShiftCore

/// Serializes potentially blocking preferences/filter work away from UI state.
actor PreferencesWorker {
    typealias ReadValue = @Sendable (String, String) -> Any?
    typealias WriteValue = @Sendable (String, String, Any?) throws -> Void

    private let dock = "com.apple.dock"
    private let windowManager = "com.apple.WindowManager"
    private let readValue: ReadValue
    private let writeValue: WriteValue
    private var dockNeedsReload = false
    private lazy var colorFilter = Result { try ColorFilterAPI() }
    private lazy var reduceMotion = Result { try ReduceMotionAPI() }

    init(readValue: @escaping ReadValue = { PreferencesWorker.systemValue($0, $1) },
        writeValue: @escaping WriteValue = { try PreferencesWorker.systemWrite($0, $1, $2) }) {
        self.readValue = readValue
        self.writeValue = writeValue
    }

    private static func systemValue(_ domain: String, _ key: String) -> Any? {
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func systemWrite(_ domain: String, _ key: String, _ value: Any?) throws {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw MonkError("macOS refused to save \(domain) → \(key).")
        }
    }

    private func value(_ domain: String, _ key: String) -> Any? { readValue(domain, key) }

    private func write(_ domain: String, _ key: String, _ value: Any?) throws {
        try writeValue(domain, key, value)
        if domain == dock { dockNeedsReload = true }
    }

    private func keys(_ feature: Feature) -> (String, [String])? {
        switch feature {
        case .instantDock: return (dock, ["autohide-delay", "autohide-time-modifier"])
        case .stageManager: return (windowManager, ["GloballyEnabled"])
        case .hideRecentApps: return (windowManager, ["AutoHide"])
        case .oneWindowAtATime: return (windowManager, ["AppWindowGroupingBehavior"])
        case .hideDesktopItems:
            return (windowManager, ["StandardHideDesktopIcons", "HideDesktop", "StandardHideWidgets", "StageManagerHideWidgets"])
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
                detail: "Automatically enables Stage Manager. Turning this mode off or choosing dimming restores its previous state.")
        case .hideDesktopItems:
            let keys = keys(feature)!.1
            let hidden = try keys.map { key -> Bool in
                // Absent keys use macOS's default visibility; preserve their absence in snapshots.
                guard let stored = value(windowManager, key) else { return false }
                guard let number = stored as? NSNumber, number == 0 || number == 1 else {
                    throw MonkError("macOS returned an unknown desktop visibility value for \(key).")
                }
                return number.boolValue
            }
            return FeatureState(enabled: hidden.allSatisfy { $0 },
                detail: hidden.contains(true) && hidden.contains(false)
                    ? "Some icons or widgets are still shown. Enable to hide them on the desktop and in Stage Manager."
                    : nil)
        case .reduceMotion:
            return FeatureState(enabled: try reduceMotion.get().read())
        case .grayscale:
            let state = try colorFilter.get().read()
            return FeatureState(enabled: state.enabled && state.type == 1)
        default: throw MonkError("\(feature.title) does not use the preferences backend.")
        }
    }

    func intensity() throws -> Double { try colorFilter.get().normalizedIntensity() }

    func snapshot(_ feature: Feature) throws -> Data {
        if feature == .hideDesktopItems { _ = try read(feature) }
        if let (domain, keys) = keys(feature) {
            let values = keys.reduce(into: [String: Any]()) { if let value = value(domain, $1) { $0[$1] = value } }
            return try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        }
        if feature == .grayscale { return try JSONEncoder().encode(colorFilter.get().read()) }
        if feature == .reduceMotion { return try JSONEncoder().encode(reduceMotion.get().read()) }
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
        case .hideDesktopItems: try setDesktopItemsHidden(true)
        case .reduceMotion: try reduceMotion.get().set(enabled: true)
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
        case .hideDesktopItems: try setDesktopItemsHidden(false)
        case .reduceMotion: try reduceMotion.get().set(enabled: false)
        case .grayscale: try colorFilter.get().disable()
        default: throw MonkError("\(feature.title) does not use the preferences backend.")
        }
    }

    private func setDesktopItemsHidden(_ hidden: Bool) throws {
        for key in keys(.hideDesktopItems)!.1 {
            try write(windowManager, key, hidden ? 1 : 0)
            guard (value(windowManager, key) as? NSNumber)?.boolValue == hidden else {
                throw MonkError("macOS did not retain \(key). Its previous value is saved.")
            }
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
        } else if feature == .reduceMotion {
            try reduceMotion.get().set(enabled: JSONDecoder().decode(Bool.self, from: data))
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
