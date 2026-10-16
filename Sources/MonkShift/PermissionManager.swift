import AppKit
import Carbon
import OSLog

@MainActor protocol AutomationPermissionClient {
    func status(ask: Bool) async -> OSStatus
    func startSystemEvents() async throws
}

@MainActor private struct SystemEventsPermissionClient: AutomationPermissionClient {
    func startSystemEvents() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func status(ask: Bool) async -> OSStatus {
        // The consent dialog can wait indefinitely. Never block AppKit's main thread.
        await Task.detached(priority: .userInitiated) { Self.determineStatus(ask: ask) }.value
    }

    nonisolated private static func determineStatus(ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let bundleID = "com.apple.systemevents"
        let result = bundleID.withCString { pointer in
            AECreateDesc(DescType(typeApplicationBundleID), pointer, bundleID.utf8.count, &target)
        }
        guard result == noErr else { return OSStatus(result) }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        Logger(subsystem: "app.monkshift.MonkShift", category: "AutomationPermission")
            .info("Automation preflight returned \(status, privacy: .public); askUser=\(ask, privacy: .public)")
        return status
    }
}

@MainActor final class PermissionManager: ObservableObject {
    @Published private(set) var granted = false
    @Published private(set) var checking = false
    @Published private(set) var requesting = false
    @Published private(set) var detail: String?
    var onUserCheckFinished: (() -> Void)?
    private let client: any AutomationPermissionClient
    private var pending: Task<Bool, Never>?

    init(client: (any AutomationPermissionClient)? = nil) {
        self.client = client ?? SystemEventsPermissionClient()
    }

    func refresh() async -> Bool { await beginCheck(ask: false).value }
#if MONKSHIFT_PREVIEW
    func grantForPreview() { granted = true }
#endif

    func request() { userCheck(ask: true) }
    func checkAgain() { userCheck(ask: false) }

    private func userCheck(ask: Bool) {
        guard !checking else { return }
        let task = beginCheck(ask: ask)
        Task { @MainActor in
            _ = await task.value
            onUserCheckFinished?()
        }
    }

    private func beginCheck(ask: Bool) -> Task<Bool, Never> {
        if let pending { return pending }
        checking = true
        requesting = ask
        let task = Task { @MainActor in
            defer { checking = false; requesting = false; pending = nil }
            do {
                if ask { try await client.startSystemEvents() }
                var result = await client.status(ask: ask)
                if result == procNotFound {
                    // System Events exits when idle. The preflight API requires a running
                    // target; -600 says nothing about the user's stored Automation grant.
                    try await client.startSystemEvents()
                    result = await client.status(ask: ask)
                }
                let allowed = result == noErr
                if granted != allowed { granted = allowed }
                detail = message(for: result)
                return allowed
            } catch {
                granted = false
                detail = "Could not start System Events to check Automation permission. \(error.localizedDescription)"
                return false
            }
        }
        pending = task
        return task
    }

    private func message(for status: OSStatus) -> String? {
        switch status {
        case OSStatus(noErr): return nil
        case OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent):
            return "Allow System Events under Privacy & Security → Automation → MonkShift. Then click Check Again. (\(status))"
        case OSStatus(procNotFound):
            return "System Events is not available yet. Click Check Again to retry. (\(status))"
        default:
            return "Could not check Automation permission. Click Check Again to retry. (\(status))"
        }
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}
