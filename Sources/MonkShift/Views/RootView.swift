import SwiftUI
import MonkShiftCore

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var permissions: PermissionManager
    init(model: AppModel) { self.model = model; self.permissions = model.permissions }

    var body: some View {
        Group {
            if permissions.granted { ControlsView(model: model) }
            else { PermissionView(permissions: permissions) }
        }
        .frame(minWidth: 540, idealWidth: 560, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refresh() }
    }
}

struct PermissionView: View {
    @ObservedObject var permissions: PermissionManager
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 40)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to MonkShift").font(.largeTitle.weight(.semibold))
                Text("A quieter Mac. A little more focus.").font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Label("Open source · MIT", systemImage: "chevron.left.forwardslash.chevron.right")
                Label("100% offline", systemImage: "wifi.slash")
            }
            .font(.callout.weight(.medium))
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Allow control of System Events").font(.headline)
                Text("MonkShift needs Automation permission to read and change your Dock and menu bar settings. macOS will ask you to allow access to System Events.")
                Text("No accounts, analytics, network requests, screen recording, or keyboard monitoring. Your saved settings stay on this Mac.")
                    .foregroundStyle(.secondary)
            }
            if let detail = permissions.detail {
                Text(detail).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button(permissions.requesting ? "Waiting for macOS…" : permissions.checking ? "Checking permission…" : "Grant Automation Permission") { permissions.request() }
                    .buttonStyle(.borderedProminent).disabled(permissions.checking)
                Button("Open System Settings") { permissions.openSettings() }
            }
            Button("Check Again") { permissions.checkAgain() }
                .disabled(permissions.checking)
            Text("Controls unlock after permission is granted. You can quit at any time.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(32)
    }
}

struct ControlsView: View {
    @ObservedObject var model: AppModel
    @State private var showShortcuts = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MonkShift").font(.title.weight(.semibold))
                        Text("Focus controls for your Mac.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                        .labelStyle(.iconOnly).help("Read current macOS settings")
                }
                SettingsStatusView(model: model)
                Button { model.toggleMonk() } label: {
                    HStack {
                        Image(systemName: model.displayedHasSession ? "arrow.uturn.backward" : "circle.lefthalf.filled")
                        Text(model.displayedHasSession ? "Disable Monk Mode · Restore Previous Settings" : "Monk Mode · Enable All")
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canChange)
                Text(model.hasSession ? "Your previous settings are saved. Quitting keeps the current settings." : "Previous settings are saved before changes are applied.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = model.generalError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    }
                    group("Dock & Menu Bar", features: [.instantDock, .hideDock, .hideMenuBar])
                    group("Stage Manager", features: [.stageManager, .hideRecentApps, .oneWindowAtATime])
                    group("Display", features: [.blackWallpaper, .grayscale])
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Grayscale intensity")
                            Spacer()
                            Text("\(Int((model.intensity * 100).rounded()))%")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $model.intensity, in: 0...1) { editing in
                            model.isEditingIntensity = editing
                            if !editing { model.commitIntensity() }
                        }
                        .accessibilityLabel("Grayscale intensity")
                        .accessibilityValue("\(Int((model.intensity * 100).rounded())) percent")
                        .disabled(!model.canAdjustIntensity)
                        Text("Applied when you release the slider. 50% by default.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button("Shortcuts…") { showShortcuts = true }.disabled(!model.canChange)
                Button("Restore All Changes") { model.restoreAll() }
                    .disabled(!model.canChange || (!model.displayedHasSession && !model.hasIndividualChanges && model.requestedValues.isEmpty))
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .sheet(isPresented: $showShortcuts) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Global Keyboard Shortcuts").font(.title2.weight(.semibold))
                ShortcutList(manager: model.shortcuts)
                HStack {
                    Spacer()
                    Button("Done") { showShortcuts = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(width: 500)
        }
    }

    private func group(_ title: String, features: [Feature]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ForEach(features) { feature in FeatureRow(feature: feature, model: model) }
        }
    }
}

struct FeatureRow: View {
    let feature: Feature
    @ObservedObject var model: AppModel
    var body: some View {
        let state = model.states[feature]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(feature.title, isOn: Binding(
                    get: { model.displayedEnabled(feature) == true },
                    set: { model.set(feature, enabled: $0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(!model.canChange || state?.available != true || state?.enabled == nil)
                Spacer(minLength: 8)
                Text(state?.available == false ? "Unavailable" : model.displayedEnabled(feature).map { $0 ? "On" : "Off" } ?? "Unknown")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let detail = model.issue(for: feature) ?? state?.detail {
                Text(detail).font(.callout).foregroundStyle(model.issue(for: feature) == nil ? Color.secondary : Color.red)
                    .padding(.leading, 20).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}
