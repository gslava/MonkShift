#if MONKSHIFT_PREVIEW
// Developer-only renderer. Excluded entirely from the release binary.
import AppKit
import SwiftUI

@main enum PreviewRenderer {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let theme = dark ? "dark" : "light"
            for state in AppModel.PreviewState.allCases {
                let model = AppModel.preview(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MonkShiftPreview-\(UUID().uuidString)"), state: state)
                let name = state == .off ? "controls-\(theme)" : "controls-\(state.rawValue)-\(theme)"
                try render(ControlsView(model: model).environment(\.colorScheme, scheme),
                    name: name, output: output, dark: dark)
                if state == .unavailable {
                    try render(ControlsView(model: model).environment(\.colorScheme, scheme),
                        name: "controls-minimum-\(theme)", output: output, dark: dark, size: NSSize(width: 540, height: 620))
                }
                model.shortcuts.shutdown()
            }
            try render(PermissionView(permissions: PermissionManager()).environment(\.colorScheme, scheme),
                name: dark ? "permission-dark" : "permission-light", output: output, dark: dark)
            try render(VStack(spacing: 24) {
                Image(nsImage: MonkIcon.menuBarImage()).foregroundStyle(.primary)
                Image(nsImage: MonkIcon.menuBarImage()).resizable().interpolation(.none)
                    .foregroundStyle(.primary).frame(width: 144, height: 144)
            }.environment(\.colorScheme, scheme), name: "menu-icon-\(theme)", output: output, dark: dark,
                size: NSSize(width: 220, height: 240))
            for (name, intensity, enabled, filterEnabled) in [
                ("active", 0.5, true, true), ("off", 0.25, true, false), ("disabled", 1.0, false, true),
                ("minimum", 0.0, true, true), ("maximum", 1.0, true, true)
            ] {
                try render(IntensityMenuPreview(intensity: intensity, enabled: enabled, filterEnabled: filterEnabled)
                    .environment(\.colorScheme, scheme), name: "intensity-menu-\(name)-\(theme)",
                    output: output, dark: dark, size: NSSize(width: 280, height: 88))
            }
        }
        print("Rendered fixture previews; no permission requests, shortcuts, or system setting writes.")
    }

    @MainActor private static func render<V: View>(_ view: V, name: String, output: URL, dark: Bool,
        size: NSSize = NSSize(width: 560, height: 800)) throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.wantsLayer = true
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        hosting.displayIfNeeded()
        hosting.layer?.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw NSError(domain: "Preview", code: 1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 2) }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        window.contentView = nil
    }
}

private struct IntensityMenuPreview: NSViewRepresentable {
    let intensity: Double
    let enabled: Bool
    let filterEnabled: Bool

    func makeNSView(context: Context) -> GrayscaleIntensityMenuView {
        GrayscaleIntensityMenuView(intensity: intensity, enabled: enabled, filterEnabled: filterEnabled,
            onEditingChanged: { _ in }, onCommit: { _ in })
    }

    func updateNSView(_ view: GrayscaleIntensityMenuView, context: Context) {
        view.update(intensity: intensity, enabled: enabled, filterEnabled: filterEnabled)
    }
}
#endif
