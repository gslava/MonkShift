import AppKit
import SwiftUI
import MonkShiftCore

#if !MONKSHIFT_PREVIEW
@main enum MonkShiftApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MonkShift", isDirectory: true)
        do {
            switch try SingleInstanceLock.acquire(directory: directory) {
            case .alreadyRunning(let pid):
                if let pid { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
                DistributedNotificationCenter.default().postNotificationName(AppDelegate.reopenNotification,
                    object: String(getuid()), userInfo: nil, deliverImmediately: true)
            case .acquired(let lock):
                let delegate = AppDelegate(directory: directory)
                application.delegate = delegate
                withExtendedLifetime((delegate, lock)) { application.run() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "MonkShift could not start safely"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
#endif

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static let reopenNotification = Notification.Name("app.monkshift.MonkShift.reopen")
    private let directory: URL
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var reopenObserver: NSObjectProtocol?

    init(directory: URL) { self.directory = directory; super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel(directory: directory)
        reopenObserver = DistributedNotificationCenter.default().addObserver(forName: Self.reopenNotification,
            object: String(getuid()), queue: .main) { [weak self] _ in
                Task { @MainActor in self?.showWindow(nil) }
            }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MonkIcon.menuBarImage()
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
        if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) }
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
        // An asynchronous refresh must not detach a slider while it is tracking.
        guard !model.isEditingIntensity else { return }
        menu.removeAllItems()
        let heading = NSMenuItem(title: "MonkShift · \(model.statusTitle)", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let detail = NSMenuItem(title: model.statusDetail, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        statusItem.button?.toolTip = "MonkShift · \(model.statusTitle)\n\(model.statusDetail)"
        if model.statusNeedsAttention {
            menu.addItem(item("Settings need attention…", #selector(showWindow(_:))))
        }
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
                if feature == .grayscale { addIntensityControl(to: menu) }
            }
            menu.addItem(.separator())
            if model.hasSession || model.hasIndividualChanges {
                let restore = item("Restore All Changes", #selector(restoreAll))
                restore.isEnabled = model.canChange
                menu.addItem(restore)
            }
        } else if model.refreshing || model.permissions.checking {
            let checking = NSMenuItem(title: "Checking Automation Permission…", action: nil, keyEquivalent: "")
            checking.isEnabled = false
            menu.addItem(checking)
        } else {
            menu.addItem(item("Grant Required Permission…", #selector(showWindow(_:))))
        }
        menu.addItem(item("Open MonkShift…", #selector(showWindow(_:))))
        menu.addItem(.separator())
        let quit = item("Quit MonkShift", #selector(quit))
        quit.isEnabled = !model.busy
        menu.addItem(quit)
        // Auto-enabling would ignore our explicit privacy and busy gates.
        menu.autoenablesItems = false
    }

    private func addIntensityControl(to menu: NSMenu) {
        let percentage = Int((model.intensity * 100).rounded())
        let control = NSMenuItem(title: "Grayscale intensity · \(percentage)%", action: nil, keyEquivalent: "")
        control.isEnabled = model.canAdjustMenuIntensity
        control.view = GrayscaleIntensityMenuView(intensity: model.intensity, enabled: model.canAdjustMenuIntensity,
            filterEnabled: model.states[.grayscale]?.enabled == true,
            onEditingChanged: { [weak model] editing in model?.isEditingIntensity = editing },
            onCommit: { [weak self, weak menu] intensity in
                guard let self else { return }
                if self.model.canAdjustMenuIntensity {
                    self.model.intensity = intensity
                    self.model.commitIntensity()
                }
                if let menu { self.populateMenu(menu) }
            })
        menu.addItem(control)
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
