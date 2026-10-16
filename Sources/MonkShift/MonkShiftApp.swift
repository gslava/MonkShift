import AppKit
import SwiftUI
import MonkShiftCore

#if !MONKSHIFT_PREVIEW
@main enum MonkShiftApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
#endif

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MonkShift", isDirectory: true)
        model = AppModel(directory: directory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "MonkShift")
        statusItem.button?.toolTip = "MonkShift — focus controls"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        model.onRefresh = { [weak self, weak menu] in
            guard let self, let menu else { return }
            self.populateMenu(menu)
        }
        installApplicationMenu()
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshIfVisible() }
            })
        }
        model.refresh()
        showWindow(nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) { model?.refresh() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(nil); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never interrupt an in-flight change between OS mutation and durable journal update.
        model?.busy == true ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.shortcuts.shutdown()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func refreshIfVisible() { if window?.isVisible == true { model.refresh() } }

    @objc private func showWindow(_ sender: Any?) {
        if window == nil {
            let controller = NSHostingController(rootView: RootView(model: model))
            let created = NSWindow(contentViewController: controller)
            created.title = "MonkShift"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 560, height: 760))
            created.minSize = NSSize(width: 540, height: 620)
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        // Release the hosting hierarchy when closed; the native menu and model remain.
        let closing = window
        window = nil
        DispatchQueue.main.async { closing?.contentViewController = nil }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh()
        populateMenu(menu)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = NSMenuItem(title: "MonkShift", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        if model.permissions.granted {
            let monk = item(model.hasSession ? "Disable Monk Mode — Restore Previous" : "Monk Mode (Enable All)", #selector(toggleMonk))
            monk.isEnabled = model.canChange
            menu.addItem(monk)
            for feature in Feature.allCases {
                let state = model.states[feature]
                let row = item(feature.title + (state?.available == false ? " — unavailable" : ""), #selector(toggleFeature(_:)))
                row.representedObject = feature.rawValue
                row.state = state?.enabled == true ? .on : state?.enabled == false ? .off : .mixed
                row.isEnabled = model.canChange && state?.available == true && state?.enabled != nil
                row.toolTip = model.issue(for: feature) ?? state?.detail
                menu.addItem(row)
            }
            menu.addItem(.separator())
            if model.hasSession || model.hasIndividualChanges {
                let restore = item("Restore All Changes", #selector(restoreAll))
                restore.isEnabled = model.canChange
                menu.addItem(restore)
            }
            if model.generalError != nil || !model.issues.isEmpty {
                menu.addItem(item("Settings need attention…", #selector(showWindow(_:))))
            }
        } else if model.refreshing || model.permissions.checking {
            let checking = NSMenuItem(title: "Checking Automation Permission…", action: nil, keyEquivalent: "")
            checking.isEnabled = false
            menu.addItem(checking)
        } else {
            menu.addItem(item("Grant Required Permission…", #selector(showWindow(_:))))
        }
        menu.addItem(item("Open MonkShift…", #selector(showWindow(_:))))
        let about = NSMenuItem(title: "Offline · Open source · MIT", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = item("Quit MonkShift", #selector(quit))
        quit.isEnabled = !model.busy
        menu.addItem(quit)
        // Auto-enabling would ignore our explicit privacy and busy gates.
        menu.autoenablesItems = false
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    @objc private func toggleMonk() { model.toggleMonk() }
    @objc private func toggleFeature(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let feature = Feature(rawValue: raw) else { return }
        model.toggle(feature)
    }
    @objc private func restoreAll() { model.restoreAll() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func installApplicationMenu() {
        let main = NSMenu()
        let app = NSMenuItem()
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit MonkShift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        app.submenu = menu
        main.addItem(app)
        NSApp.mainMenu = main
    }
}
