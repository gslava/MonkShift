import AppKit
import Carbon

@MainActor private final class FakePermissionClient: AutomationPermissionClient {
    var statuses: [OSStatus]
    var requests: [Bool] = []
    var starts = 0
    var failStart = false

    init(_ statuses: [OSStatus]) { self.statuses = statuses }

    func status(ask: Bool) async -> OSStatus {
        requests.append(ask)
        await Task.yield()
        precondition(!statuses.isEmpty, "Unexpected extra permission check")
        return statuses.removeFirst()
    }

    func startSystemEvents() async throws {
        starts += 1
        if failStart { throw NSError(domain: "PermissionChecks", code: 1) }
        await Task.yield()
    }
}

@main private enum PermissionManagerChecks {
    @MainActor static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }

        let idleClient = FakePermissionClient([OSStatus(procNotFound), OSStatus(noErr)])
        let idle = PermissionManager(client: idleClient)
        let recovered = await idle.refresh()
        check(recovered && idle.granted && idle.detail == nil && idleClient.starts == 1
            && idleClient.requests == [false, false] && !idle.checking,
            "Idle System Events restarts and existing permission unlocks controls without prompting")

        let deniedClient = FakePermissionClient([OSStatus(errAEEventNotPermitted)])
        let denied = PermissionManager(client: deniedClient)
        let deniedResult = await denied.refresh()
        check(!deniedResult && !denied.granted && deniedClient.starts == 0 && deniedClient.requests == [false]
            && denied.detail?.contains("Automation") == true,
            "Denied permission stays blocked without a prompt or unnecessary launch")

        let firstClient = FakePermissionClient([OSStatus(procNotFound), OSStatus(errAEEventWouldRequireUserConsent)])
        let first = PermissionManager(client: firstClient)
        let firstResult = await first.refresh()
        check(!firstResult && !first.granted && firstClient.requests == [false, false],
            "Starting System Events never silently grants or requests first-launch consent")

        let revokedClient = FakePermissionClient([OSStatus(noErr), OSStatus(procNotFound), OSStatus(errAEEventNotPermitted)])
        let revoked = PermissionManager(client: revokedClient)
        _ = await revoked.refresh()
        let revokedResult = await revoked.refresh()
        check(!revokedResult && !revoked.granted && revokedClient.starts == 1,
            "Revoked permission blocks controls even after a previous successful check")

        let missingClient = FakePermissionClient([OSStatus(procNotFound), OSStatus(procNotFound)])
        let missing = PermissionManager(client: missingClient)
        let missingResult = await missing.refresh()
        check(!missingResult && missingClient.starts == 1 && missing.detail?.contains("not available") == true,
            "Unavailable System Events is reported separately and retry is bounded")

        let failedClient = FakePermissionClient([OSStatus(procNotFound)])
        failedClient.failStart = true
        let failed = PermissionManager(client: failedClient)
        let failedResult = await failed.refresh()
        check(!failedResult && !failed.granted && !failed.checking && failed.detail?.contains("Could not start") == true,
            "Launch failure keeps controls locked and ends the checking state")

        let concurrentClient = FakePermissionClient([OSStatus(procNotFound), OSStatus(noErr)])
        let concurrent = PermissionManager(client: concurrentClient)
        async let firstCheck = concurrent.refresh()
        async let secondCheck = concurrent.refresh()
        let results = await (firstCheck, secondCheck)
        check(results.0 && results.1 && concurrent.granted && concurrentClient.starts == 1
            && concurrentClient.requests == [false, false],
            "Concurrent menu and window refreshes share one launch and permission check")

        let requestClient = FakePermissionClient([OSStatus(noErr)])
        let request = PermissionManager(client: requestClient)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            request.onUserCheckFinished = { continuation.resume() }
            request.request()
        }
        check(request.granted && !request.requesting && !request.checking && requestClient.starts == 1
            && requestClient.requests == [true],
            "Explicit permission request notifies the model after completion")

        print("8 permission tests, \(failures) failures. No system services started or privacy prompts requested.")
        if failures > 0 { exit(1) }
    }
}
