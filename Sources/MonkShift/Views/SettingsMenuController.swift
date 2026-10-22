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
    private var dimmingIntensityView: GrayscaleIntensityMenuView?
    private let profileMenu = NSMenu()

    init(model: AppModel, showWindow: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.showWindow = showWindow
        self.quit = quit
        super.init()
        menu.autoenablesItems = false
        profileMenu.autoenablesItems = false
        update()
    }

    func update() {
        guard !model.isEditingIntensity, !model.isEditingDimmingIntensity else { return }
        var rows: [NSMenuItem] = []
        rows.append(item("heading", "MonkShift · \(model.statusTitle)"))
        rows.append(item("detail", model.statusDetail))
        if model.statusNeedsAttention {
            rows.append(item("attention", "Settings need attention…", #selector(openWindow)))
        }
        rows.append(separator("headerSeparator"))
        if model.permissions.granted {
            rows.append(profilesControl())
            let monk = item("monk", model.displayedHasSession ? "Disable Monk Mode — Restore Previous" : "Monk Mode (Enable Selected Settings)", #selector(toggleMonk))
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
                if feature == .dimBackground {
                    rows.append(dimmingIntensityControl())
                    if !model.accessibility.granted {
                        rows.append(item("accessibility", "Allow Accessibility for Dimming…", #selector(requestAccessibility)))
                    }
                }
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
        reconcile(rows, in: menu)
    }

    private func reconcile(_ rows: [NSMenuItem], in target: NSMenu) {
        let retained = Set(rows.map(ObjectIdentifier.init))
        for row in target.items where !retained.contains(ObjectIdentifier(row)) { target.removeItem(row) }
        for (index, row) in rows.enumerated() where target.index(of: row) != index {
            if row.menu === target { target.removeItem(row) }
            target.insertItem(row, at: index)
        }
    }

    private func profilesControl() -> NSMenuItem {
        let row = item("profiles", "Profile: \(model.selectedProfileName)")
        row.isEnabled = model.canSelectProfile
        if row.submenu !== profileMenu { row.submenu = profileMenu }
        var rows = model.profiles.map { profile in
            let choice = item("profile-\(profile.id)", profile.name, #selector(selectProfile(_:)))
            choice.representedObject = profile.id
            choice.state = profile.id == model.selectedProfileID ? .on : .off
            choice.isEnabled = model.canSelectProfile
            return choice
        }
        rows.append(separator("profilesSeparator"))
        let create = item("newProfile", "New Profile…", #selector(newProfile))
        create.isEnabled = model.canCreateProfile
        rows.append(create)
        reconcile(rows, in: profileMenu)
        return row
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

    private func dimmingIntensityControl() -> NSMenuItem {
        let row = item("dimmingIntensity", "Background dimming intensity · \(Int((model.dimmingIntensity * 100).rounded()))%")
        if dimmingIntensityView == nil {
            dimmingIntensityView = GrayscaleIntensityMenuView(intensity: model.dimmingIntensity,
                enabled: model.canAdjustMenuDimmingIntensity, filterEnabled: model.displayedEnabled(.dimBackground) == true,
                label: "Background dimming", maximum: 0.9, disabledHint: "Enable background dimming to adjust.",
                onEditingChanged: { [weak model] editing in model?.isEditingDimmingIntensity = editing },
                onCommit: { [weak self] intensity in
                    guard let self else { return }
                    if model.canAdjustMenuDimmingIntensity {
                        model.dimmingIntensity = intensity
                        model.commitDimmingIntensity()
                    }
                    update()
                })
            row.view = dimmingIntensityView
        }
        row.isEnabled = model.canAdjustMenuDimmingIntensity
        dimmingIntensityView?.update(intensity: model.dimmingIntensity, enabled: model.canAdjustMenuDimmingIntensity,
            filterEnabled: model.displayedEnabled(.dimBackground) == true)
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
    @objc private func requestAccessibility() { showWindow(); model.accessibility.request() }
    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.selectProfile(id: id)
    }
    @objc private func newProfile() { showWindow(); model.showNewProfile = true }
}
