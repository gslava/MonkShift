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
        let model = AppModel.preview(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MonkShiftPreview-\(UUID().uuidString)"))
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            try render(ControlsView(model: model).environment(\.colorScheme, scheme),
                name: dark ? "controls-dark" : "controls-light", output: output, dark: dark)
            try render(PermissionView(permissions: PermissionManager()).environment(\.colorScheme, scheme),
                name: dark ? "permission-dark" : "permission-light", output: output, dark: dark)
        }
        model.shortcuts.shutdown()
        print("Rendered fixture previews; no permission requests, shortcuts, or system setting writes.")
    }

    @MainActor private static func render<V: View>(_ view: V, name: String, output: URL, dark: Bool) throws {
        let size = NSSize(width: 560, height: 760)
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
#endif
