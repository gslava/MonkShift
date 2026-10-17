import AppKit
import MonkShiftCore

/// Keeps native menu items and the slider alive across asynchronous state reads.
@MainActor final class SettingsMenuController: NSObject {
    let menu = NSMenu()
    private let model: AppModel
    private let showWindow: () -> Void
    private let quit: () -> Void
    private var items: [String: NSMenuItem] = [:]
    private var intensityView: GrayscaleIntensityMenuView?

    init(model: AppModel, showWindow: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.showWindow = showWindow
        self.quit = quit
        super.init()
        menu.autoenablesItems = false
        update()
    }

    func update() {
        guard !model.isEditingIntensity else { return }
        var rows: [NSMenuItem] = []
        rows.append(item("heading", "MonkShift · \(model.statusTitle)"))
        rows.append(item("detail", model.statusDetail))
        if model.statusNeedsAttention {
            rows.append(item("attention", "Settings need attention…", #selector(openWindow)))
        }
        rows.append(separator("headerSeparator"))
        if model.permissions.granted {
            let monk = item("monk", model.displayedHasSession ? "Disable Monk Mode — Restore Previous" : "Monk Mode (Enable All)", #selector(toggleMonk))
            monk.isEnabled = model.canChange
            rows.append(monk)
            for feature in Feature.allCases {
                let state = model.states[feature]
                let row = item(feature.rawValue, feature.title + (state?.available == false ? " — unavailable" : ""), #selector(toggleFeature(_:)))
                row.representedObject = feature.rawValue
                let enabled = model.displayedEnabled(feature)
                row.state = enabled == true ? .on : enabled == false ? .off : .mixed
                row.isEnabled = model.canChange && state?.available == true && state?.enabled != nil
                row.toolTip = model.issue(for: feature) ?? state?.detail
                rows.append(row)
                if feature == .grayscale { rows.append(intensityControl()) }
            }
            rows.append(separator("controlsSeparator"))
            let restore = item("restore", "Restore All Changes", #selector(restoreAll))
            restore.isEnabled = model.canChange && (model.hasSession || model.displayedHasSession ||
                model.hasIndividualChanges || !model.requestedValues.isEmpty)
            rows.append(restore)
        } else if model.refreshing || model.permissions.checking {
            rows.append(item("checking", "Checking Automation Permission…"))
        } else {
            rows.append(item("permission", "Grant Required Permission…", #selector(openWindow)))
        }
        rows.append(item("open", "Open MonkShift…", #selector(openWindow)))
        rows.append(separator("footerSeparator"))
        rows.append(item("quit", "Quit MonkShift", #selector(quitApp)))

        // Reconcile only structural changes (permission, restore/error rows).
        // Ordinary refreshes merely change existing titles/checkmarks/values.
        let retained = Set(rows.map(ObjectIdentifier.init))
        for row in menu.items where !retained.contains(ObjectIdentifier(row)) { menu.removeItem(row) }
        for (index, row) in rows.enumerated() where menu.index(of: row) != index {
            if row.menu === menu { menu.removeItem(row) }
            menu.insertItem(row, at: index)
        }
    }

    private func item(_ id: String, _ title: String, _ action: Selector? = nil) -> NSMenuItem {
        let row: NSMenuItem
        if let existing = items[id] { row = existing }
        else {
            row = NSMenuItem(title: title, action: action, keyEquivalent: "")
            row.target = self
            row.isEnabled = action != nil
            items[id] = row
        }
        if row.title != title { row.title = title }
        return row
    }

    private func separator(_ id: String) -> NSMenuItem {
        if let existing = items[id] { return existing }
        let row = NSMenuItem.separator()
        items[id] = row
        return row
    }

    private func intensityControl() -> NSMenuItem {
        let row = item("intensity", "Grayscale intensity · \(Int((model.intensity * 100).rounded()))%")
        if intensityView == nil {
            intensityView = GrayscaleIntensityMenuView(intensity: model.intensity, enabled: model.canAdjustMenuIntensity,
                filterEnabled: model.displayedEnabled(.grayscale) == true,
                onEditingChanged: { [weak model] editing in model?.isEditingIntensity = editing },
                onCommit: { [weak self] intensity in
                    guard let self else { return }
                    if model.canAdjustMenuIntensity {
                        model.intensity = intensity
                        model.commitIntensity()
                    }
                    update()
                })
            row.view = intensityView
        }
        row.isEnabled = model.canAdjustMenuIntensity
        intensityView?.update(intensity: model.intensity, enabled: model.canAdjustMenuIntensity,
            filterEnabled: model.displayedEnabled(.grayscale) == true)
        return row
    }

    @objc private func openWindow() { showWindow() }
    @objc private func toggleMonk() { model.toggleMonk() }
    @objc private func toggleFeature(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let feature = Feature(rawValue: raw) else { return }
        model.toggle(feature)
    }
    @objc private func restoreAll() { model.restoreAll() }
    @objc private func quitApp() { quit() }
}
