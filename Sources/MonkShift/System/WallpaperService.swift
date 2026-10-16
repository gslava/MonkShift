import AppKit
import MonkShiftCore

@MainActor final class WallpaperService {
    struct DisplayState: Codable {
        let id: String
        let url: URL
        let options: Data
    }
    private let blackURL: URL
    init(directory: URL) { blackURL = directory.appendingPathComponent("black.png") }

    private func id(_ screen: NSScreen) throws -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            throw MonkError("Could not identify a connected display.")
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    func snapshot() throws -> Data {
        guard !NSScreen.screens.isEmpty else { throw MonkError("No connected displays are available.") }
        let states = try NSScreen.screens.map { screen -> DisplayState in
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
                throw MonkError("Could not read the wallpaper for \(screen.localizedName).")
            }
            let options = (NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
                .reduce(into: [String: Any]()) { $0[$1.key.rawValue] = $1.value }
            let data = try NSKeyedArchiver.archivedData(withRootObject: options, requiringSecureCoding: true)
            return DisplayState(id: try id(screen), url: url, options: data)
        }
        return try JSONEncoder().encode(states)
    }

    func isBlack() -> Bool {
        !NSScreen.screens.isEmpty && NSScreen.screens.allSatisfy {
            NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL == blackURL.standardizedFileURL
        }
    }

    func apply() throws {
        if !FileManager.default.fileExists(atPath: blackURL.path) {
            try FileManager.default.createDirectory(at: blackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw MonkError("Could not create a black wallpaper image.")
            }
            for y in 0..<8 { for x in 0..<8 { bitmap.setColor(.black, atX: x, y: y) } }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw MonkError("Could not encode the wallpaper image.") }
            try png.write(to: blackURL, options: .atomic)
        }
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(blackURL, for: screen, options: [
                .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true
            ])
        }
        guard isBlack() else { throw MonkError("macOS did not apply the black wallpaper on every connected display.") }
    }

    func restore(_ data: Data) throws {
        let states = try JSONDecoder().decode([DisplayState].self, from: data)
        var missing: [String] = []
        for state in states {
            guard let screen = NSScreen.screens.first(where: { (try? id($0)) == state.id }) else {
                missing.append(state.id)
                continue
            }
            // NSColor can occur in the desktop image options dictionary.
            let classes: [AnyClass] = [NSDictionary.self, NSString.self, NSNumber.self, NSColor.self, NSColorSpace.self, NSData.self, NSArray.self]
            let values = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: state.options) as? [String: Any] ?? [:]
            let options = values.reduce(into: [NSWorkspace.DesktopImageOptionKey: Any]()) { $0[.init(rawValue: $1.key)] = $1.value }
            try NSWorkspace.shared.setDesktopImageURL(state.url, for: screen, options: options)
            guard NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL == state.url.standardizedFileURL else {
                throw MonkError("macOS did not restore the wallpaper on \(screen.localizedName).")
            }
        }
        if !missing.isEmpty { throw MonkError("Reconnect \(missing.count) saved display(s), then retry wallpaper restoration.") }
    }
}
