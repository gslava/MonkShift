import AppKit
import ApplicationServices

@MainActor protocol AccessibilityPermissionClient {
    func isTrusted(prompt: Bool) -> Bool
}

@MainActor private struct SystemAccessibilityPermissionClient: AccessibilityPermissionClient {
    func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
    }
}

@MainActor final class AccessibilityPermissionManager: ObservableObject {
    @Published private(set) var granted = false
    private let client: any AccessibilityPermissionClient
    private var requestedAtStartup = false
    var onChange: (() -> Void)?

    init(client: (any AccessibilityPermissionClient)? = nil) {
        self.client = client ?? SystemAccessibilityPermissionClient()
    }

    @discardableResult func refresh() -> Bool {
        let allowed = client.isTrusted(prompt: false)
        if granted != allowed { granted = allowed; onChange?() }
        return allowed
    }

    func requestAtStartup() {
        guard !requestedAtStartup else { return }
        requestedAtStartup = true
        if !refresh() { request() }
    }

    func request() {
        granted = client.isTrusted(prompt: true)
        onChange?()
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

#if MONKSHIFT_PREVIEW
    func grantForPreview() { granted = true }
    func denyForPreview() { granted = false }
#endif
}
