import SwiftUI
import MonkShiftCore

enum ControlsLayout {
    static let size = CGSize(width: 716, height: 568)
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var permissions: PermissionManager
    init(model: AppModel) { self.model = model; self.permissions = model.permissions }

    var body: some View {
        Group {
            if permissions.granted { ControlsView(model: model) }
            else { PermissionView(permissions: permissions) }
        }
        .frame(minWidth: ControlsLayout.size.width, idealWidth: ControlsLayout.size.width, maxWidth: .infinity,
            minHeight: ControlsLayout.size.height, idealHeight: ControlsLayout.size.height, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refresh() }
    }
}

struct PermissionView: View {
    @ObservedObject var permissions: PermissionManager
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                Text("Accessibility is requested at startup for background dimming. You can use the other controls without it.")
                Text("No accounts, analytics, network requests, screen recording, or keyboard monitoring. Your saved settings stay on this Mac.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
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
            Text(AppVersion.label).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).help(AppVersion.detail)
            Spacer(minLength: 0)
        }
        .padding(32)
    }
}

struct ControlsView: View {
    @ObservedObject var model: AppModel
    @State private var showShortcuts = false
    @State private var showIssues = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("MonkShift").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                        .labelStyle(.iconOnly).help("Read current macOS settings")
                }
                HStack(alignment: .top, spacing: 20) {
                    SettingsStatusView(model: model)
                    VStack(alignment: .trailing, spacing: 6) {
                        Button { model.toggleMonk() } label: {
                            Text(model.displayedHasSession ? "Disable Monk Mode" : "Enable Monk Mode")
                                .frame(minWidth: 160)
                        }
                        .buttonStyle(MonkModeButtonStyle())
                        .disabled(!model.canChange)
                        .help(model.displayedHasSession ? "Restore the settings saved before Monk Mode." : "Save previous settings, then enable Monk Mode.")
                        Text(model.hasSession ? "Disable to restore previous settings." : "Previous settings are saved before changes.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    SettingsCard("Dock & Menu Bar") {
                        FeatureRow(feature: .instantDock, model: model)
                        FeatureRow(feature: .hideDock, model: model)
                        FeatureRow(feature: .hideMenuBar, model: model)
                    }
                    DimmingControlsView(model: model)
                }
                HStack(alignment: .top, spacing: 12) {
                    SettingsCard("Stage Manager") {
                        FeatureRow(feature: .stageManager, model: model)
                        FeatureRow(feature: .hideRecentApps, model: model)
                        Text("Recent apps are hidden while Stage Manager is on.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SettingsCard("Display") {
                        FeatureRow(feature: .hideDesktopItems, model: model)
                        FeatureRow(feature: .reduceMotion, model: model)
                        FeatureRow(feature: .blackWallpaper, model: model)
                        FeatureRow(feature: .grayscale, model: model)
                        IntensityControl(title: "Grayscale intensity", value: $model.intensity, maximum: 1) { editing in
                            model.isEditingIntensity = editing
                            if !editing { model.commitIntensity() }
                        }
                        .disabled(!model.canAdjustIntensity)
                        .help("0–100%. Applied when you release the slider. When grayscale is off, saves the amount for the next enable.")
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            HStack(spacing: 12) {
                Button("Shortcuts…") { showShortcuts = true }.disabled(!model.canChange)
                Spacer()
                if model.statusNeedsAttention {
                    Button("Review Issues…", systemImage: "exclamationmark.triangle") { showIssues = true }
                        .foregroundStyle(.orange)
                        .popover(isPresented: $showIssues) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Settings need attention").font(.headline)
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 12) {
                                        if let error = model.generalError { Text(error) }
                                        ForEach(model.issues) { issue in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(issue.feature.title).fontWeight(.medium)
                                                Text(issue.message)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                }
                                .frame(maxHeight: 240)
                            }
                            .padding(16).frame(width: 360)
                        }
                }
                Button("Restore All") { model.restoreAll() }
                    .disabled(!model.canChange || (!model.displayedHasSession && !model.hasIndividualChanges && model.requestedValues.isEmpty))
                    .help("Restore the saved Monk Mode session and individual changes.")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay {
                Text(AppVersion.label).font(.callout).foregroundStyle(.secondary).help(AppVersion.detail)
            }
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
}

private struct MonkModeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

struct DimmingControlsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var accessibility: AccessibilityPermissionManager

    init(model: AppModel) { self.model = model; accessibility = model.accessibility }

    var body: some View {
        SettingsCard("Window Focus") {
            FeatureRow(feature: .oneWindowAtATime, model: model)
            FeatureRow(feature: .dimBackground, model: model)
            IntensityControl(title: "Dimming", value: $model.dimmingIntensity, maximum: 0.9,
                accessibilityTitle: "Background dimming intensity") { editing in
                model.isEditingDimmingIntensity = editing
                if !editing { model.commitDimmingIntensity() }
            }
            .disabled(!model.canAdjustDimmingIntensity)
            .help("0–90%. Applied when you release the slider. Background dimming stops when MonkShift quits.")
            HStack {
                if !accessibility.granted {
                    Button("Allow Accessibility…") { accessibility.request(); model.refresh() }
                        .controlSize(.small)
                    Button("Open Settings") { accessibility.openSettings() }
                        .controlSize(.small).help("Open Privacy & Security → Accessibility, enable MonkShift, then Refresh.")
                } else {
                    Text("Choose one focus mode.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ContextHelpButton(title: "Window Focus", detail: "Choose either mode. Monk Mode uses your last choice: \(model.preferredFocusMode.title). Turning both off keeps that choice for the next Monk Mode session. Background dimming stops when MonkShift quits.")
            }
        }
    }
}

struct IntensityControl: View {
    let title: String
    @Binding var value: Double
    let maximum: Double
    var accessibilityTitle: String? = nil
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title).fixedSize()
            Slider(value: $value, in: 0...maximum, onEditingChanged: onEditingChanged)
                .labelsHidden()
                .accessibilityLabel(accessibilityTitle ?? title)
                .accessibilityValue("\(Int((value * 100).rounded())) percent")
            Text("\(Int((value * 100).rounded()))%")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
        .frame(minHeight: 24)
    }
}

struct FeatureRow: View {
    let feature: Feature
    @ObservedObject var model: AppModel

    var body: some View {
        let state = model.states[feature]
        let issue = model.issue(for: feature)
        HStack(spacing: 6) {
            Toggle(feature == .hideRecentApps ? "Hide recent apps" : feature.title, isOn: Binding(
                get: { model.displayedEnabled(feature) == true },
                set: { model.set(feature, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(!model.canChange || state?.available != true || state?.enabled == nil)
            .accessibilityLabel(feature.title)
            Spacer(minLength: 0)
            if state?.available == false || model.displayedEnabled(feature) == nil {
                Text(state?.available == false ? "Unavailable" : "Unknown")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let detail = issue ?? state?.detail {
                ContextHelpButton(title: feature.title, detail: detail,
                    needsAttention: issue != nil || state?.available == false || state?.enabled == nil)
            }
        }
        .frame(minHeight: 24)
    }
}

struct ContextHelpButton: View {
    let title: String
    let detail: String
    var needsAttention = false
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: needsAttention ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
                .frame(width: 18, height: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) details")
        .help(detail)
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .padding(16).frame(width: 320, alignment: .leading)
        }
    }
}
