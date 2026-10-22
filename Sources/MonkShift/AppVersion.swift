import Foundation

enum AppVersion {
    static var label: String {
        guard let version = information["CFBundleShortVersionString"] as? String else { return "Development build" }
        return "Version \(version)"
    }

    static var detail: String {
        guard let build = information["CFBundleVersion"] as? String else { return label }
        return "\(label) · Build \(build)"
    }

    private static let information: [String: Any] = {
#if MONKSHIFT_PREVIEW
        // The preview executable is not an app bundle. Read the same packaging metadata.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if let data = try? Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return values
        }
#endif
        return Bundle.main.infoDictionary ?? [:]
    }()
}
