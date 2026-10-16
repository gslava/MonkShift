import Foundation
import Carbon
import MonkShiftCore

enum SystemEventsChecks {
    private static func reply(_ value: Bool?) -> NSAppleEventDescriptor {
        let reply = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEAnswer),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let value { reply.setParam(NSAppleEventDescriptor(boolean: value), forKeyword: AEKeyword(keyDirectObject)) }
        return reply
    }

    static func testTypedEvents() async throws {
        let client = SystemEventsClient { event, timeout in
            try require(!Thread.isMainThread, "System Events transport ran on the main thread")
            try require(timeout == 5, "Request lost its bounded timeout")
            try require(event.eventClass == AEEventClass(kCoreEventClass), "Wrong event class")
            let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))!
            try require(direct.descriptorType == DescType(typeObjectSpecifier), "Request is not a property specifier")
            let property = direct.forKeyword( AEKeyword(keyAEKeyData))!.typeCodeValue
            let container = direct.forKeyword( AEKeyword(keyAEContainer))!
            try require(container.forKeyword( AEKeyword(keyAEKeyData))?.typeCodeValue == 0x64706173,
                "Request did not target dock preferences")
            let target = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))!
            try require(target.descriptorType == DescType(typeApplicationBundleID), "Request lost its app target")
            if event.eventID == AEEventID(kAESetData) {
                try require(property == SystemEventsClient.Setting.hideMenuBar.rawValue, "Wrong menu bar property")
                try require(event.paramDescriptor(forKeyword: AEKeyword(keyAEData))?.booleanValue == true, "Wrong write value")
                return reply(nil)
            }
            try require(property == SystemEventsClient.Setting.hideDock.rawValue, "Wrong Dock property")
            return reply(false)
        }
        let enabled = try await client.read(.hideDock)
        try require(!enabled, "An off setting was reported as enabled")
        try await client.write(.hideMenuBar, enabled: true)
    }

    @MainActor static func testMainActorRemainsResponsive() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let client = SystemEventsClient { _, _ in
            started.continuation.yield(())
            guard release.wait(timeout: .now() + 2) == .success else { throw MonkError("Test transport timed out") }
            return reply(true)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let read = Task { try await client.read(.hideDock) }
        for await _ in started.stream { break }
        // This code must run before a deliberately blocked transport is released.
        let responsive = clock.now - start < .seconds(1)
        release.signal()
        _ = try await read.value
        started.continuation.finish()
        try require(responsive, "Waiting for a system reply blocked the main actor")
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var maximum = 0
        func enter() { lock.withLock { active += 1; maximum = max(maximum, active) } }
        func leave() { lock.withLock { active -= 1 } }
        var largest: Int { lock.withLock { maximum } }
    }

    static func testTransportIsSerialized() async throws {
        let calls = Calls()
        let client = SystemEventsClient { _, _ in
            calls.enter()
            defer { calls.leave() }
            Thread.sleep(forTimeInterval: 0.03)
            return reply(true)
        }
        async let dock = client.read(.hideDock)
        async let menu = client.read(.hideMenuBar)
        _ = try await (dock, menu)
        try require(calls.largest == 1, "System requests ran concurrently")
    }

    static func testUnknownAndErrorRepliesAreRejected() async throws {
        let unknown = SystemEventsClient { _, _ in reply(nil) }
        do {
            _ = try await unknown.read(.hideDock)
            throw CheckFailure(description: "Missing reply silently became an off state")
        } catch is CheckFailure { throw CheckFailure(description: "Missing reply silently became an off state") }
        catch { try require(error.localizedDescription.contains("unknown"), "Unknown reply lost its explanation") }

        let denied = SystemEventsClient { _, _ in
            let result = reply(nil)
            result.setParam(NSAppleEventDescriptor(int32: -1743), forKeyword: AEKeyword(keyErrorNumber))
            result.setParam(NSAppleEventDescriptor(string: "Not authorized"), forKeyword: AEKeyword(keyErrorString))
            return result
        }
        do {
            try await denied.write(.hideDock, enabled: true)
            throw CheckFailure(description: "Permission failure counted as success")
        } catch is CheckFailure { throw CheckFailure(description: "Permission failure counted as success") }
        catch { try require(error.localizedDescription.contains("-1743"), "Permission error lost its code") }

        let timeout = SystemEventsClient { _, _ in throw NSError(domain: NSOSStatusErrorDomain, code: -1712) }
        do {
            _ = try await timeout.read(.hideDock)
            throw CheckFailure(description: "Timeout counted as success")
        } catch is CheckFailure { throw CheckFailure(description: "Timeout counted as success") }
        catch { try require(error.localizedDescription.contains("-1712"), "Timeout lost its code") }
    }
}
