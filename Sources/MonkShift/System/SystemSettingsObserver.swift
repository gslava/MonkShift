import AppKit

/// Observes known preference keys and public system events. There is no polling.
@MainActor final class SystemSettingsObserver {
    typealias Preferences = [(defaults: UserDefaults, keys: [String])]
    private var preferenceObserver: DefaultsChangeObserver?
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
    private var running = true
    private let isInterfaceVisible: () -> Bool
    private let onChange: () -> Void

    init(preferences: Preferences? = nil,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        applicationCenter: NotificationCenter = .default,
        isInterfaceVisible: @escaping () -> Bool = { true }, onChange: @escaping () -> Void) {
        self.isInterfaceVisible = isInterfaceVisible
        self.onChange = onChange
        preferenceObserver = DefaultsChangeObserver(preferences: preferences ?? Self.systemPreferences()) { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.onChange()
            }
        }
        for name in [NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(name, center: workspaceCenter)
        }
        // App switches can reveal wallpaper/settings edits without a documented
        // per-setting notification. Avoid full reads for these events when hidden.
        observe(NSWorkspace.didActivateApplicationNotification, center: workspaceCenter, visibleOnly: true)
        observe(NSApplication.didChangeScreenParametersNotification, center: applicationCenter)
    }

    private static func systemPreferences() -> Preferences {
        var preferences: Preferences = [(.standard, ["_HIHideMenuBar", "backgroundDimmingEnabled", "backgroundDimmingCurrentIntensity"])]
        for (domain, keys) in [
            ("com.apple.dock", ["autohide", "autohide-delay", "autohide-time-modifier", "workspaces-spans-displays"]),
            ("com.apple.WindowManager", ["GloballyEnabled", "AutoHide", "AppWindowGroupingBehavior",
                "StandardHideDesktopIcons", "HideDesktop", "StandardHideWidgets", "StageManagerHideWidgets"])
        ] {
            if let defaults = UserDefaults(suiteName: domain) { preferences.append((defaults, keys)) }
        }
        return preferences
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter, visibleOnly: Bool = false) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, !visibleOnly || self.isInterfaceVisible() else { return }
                self.onChange()
            }
        }
        notifications.append((center, token))
    }

    func stop() {
        guard running else { return }
        running = false
        preferenceObserver?.stop()
        preferenceObserver = nil
        for (center, token) in notifications { center.removeObserver(token) }
        notifications.removeAll()
    }
}

/// KVO callbacks can arrive off the main thread; only the signal crosses to UI.
private final class DefaultsChangeObserver: NSObject {
    private let preferences: SystemSettingsObserver.Preferences
    private let onChange: @Sendable () -> Void
    private var observing = true

    init(preferences: SystemSettingsObserver.Preferences, onChange: @escaping @Sendable () -> Void) {
        self.preferences = preferences
        self.onChange = onChange
        super.init()
        for (defaults, keys) in preferences {
            for key in keys {
                defaults.addObserver(self, forKeyPath: key, options: [], context: Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard context == Unmanaged.passUnretained(self).toOpaque() else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        onChange()
    }

    func stop() {
        guard observing else { return }
        observing = false
        for (defaults, keys) in preferences {
            for key in keys {
                defaults.removeObserver(self, forKeyPath: key, context: Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    deinit { stop() }
}
