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
    private var settingsMenu: SettingsMenuController!
    private var window: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var reopenObserver: NSObjectProtocol?

    init(directory: URL) { self.directory = directory; super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel(directory: directory)
        MonkModeIntentHandler.shared.model = model
        MonkShiftAppShortcuts.updateAppShortcutParameters()
        reopenObserver = DistributedNotificationCenter.default().addObserver(forName: Self.reopenNotification,
            object: String(getuid()), queue: .main) { [weak self] _ in
                Task { @MainActor in self?.showWindow(nil) }
            }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MonkIcon.menuBarImage()
        statusItem.button?.toolTip = "MonkShift — focus controls"
        settingsMenu = SettingsMenuController(model: model,
            showWindow: { [weak self] in self?.showWindow(nil) },
            quit: { NSApp.terminate(nil) })
        settingsMenu.menu.delegate = self
        statusItem.menu = settingsMenu.menu
        model.onRefresh = { [weak self] in self?.updateMenu() }
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
        // Keep Quit visually stable while allowing accepted changes to finish safely.
        if model?.prepareToQuit(onReady: { sender.reply(toApplicationShouldTerminate: true) }) == true {
            return .terminateLater
        }
        return .terminateNow
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
            created.setContentSize(NSSize(width: 560, height: 800))
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
        updateMenu()
    }

    private func updateMenu() {
        settingsMenu.update()
        statusItem.button?.toolTip = "MonkShift · \(model.statusTitle)\n\(model.statusDetail)"
    }

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
