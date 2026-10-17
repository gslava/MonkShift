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
            try require(event.eventClass == AEEventClass(kAECoreSuite), "Wrong event class")
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

    static func testCommandsMatchScriptingDictionary() async throws {
        // Use macOS's command definitions as an independent protocol reference.
        // This only reads XML; it never sends an event or requests permission.
        let dictionary = try XMLDocument(contentsOf: URL(fileURLWithPath:
            "/System/Library/Frameworks/Foundation.framework/Resources/Intrinsics.sdef"))
        let getCode = try dictionary.nodes(forXPath: "//command[@name='get']/@code").first?.stringValue
        let setCode = try dictionary.nodes(forXPath: "//command[@name='set']/@code").first?.stringValue
        try require(getCode != nil && setCode != nil, "macOS scripting command definitions are missing")

        @Sendable func code(_ value: UInt32) -> String {
            String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, encoding: .ascii)!
        }
        for setting in [SystemEventsClient.Setting.hideDock, .hideMenuBar] {
            for enabled in [false, true] {
                let client = SystemEventsClient { event, _ in
                    let command = code(event.eventClass) + code(event.eventID)
                    let value = event.paramDescriptor(forKeyword: AEKeyword(keyAEData))
                    try require(command == (value == nil ? getCode : setCode),
                        "Apple Event command \(command) does not match macOS's get/set dictionary")
                    if let value {
                        try require(value.booleanValue == enabled, "Write lost its Boolean value")
                    }
                    return reply(enabled)
                }
                let observed = try await client.read(setting)
                try require(observed == enabled, "Read lost its Boolean value")
                try await client.write(setting, enabled: enabled)
            }
        }
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

        for (code, needsPermission) in [(-1743, true), (-1744, true), (-1708, false), (-1712, false)] {
            for throwsError in [false, true] {
                let client = SystemEventsClient { _, _ in
                    if throwsError { throw NSError(domain: NSOSStatusErrorDomain, code: code) }
                    let result = reply(nil)
                    result.setParam(NSAppleEventDescriptor(int32: Int32(code)), forKeyword: AEKeyword(keyErrorNumber))
                    result.setParam(NSAppleEventDescriptor(string: "Request failed"), forKeyword: AEKeyword(keyErrorString))
                    return result
                }
                do {
                    if throwsError { _ = try await client.read(.hideDock) }
                    else { try await client.write(.hideMenuBar, enabled: true) }
                    throw CheckFailure(description: "System Events failure counted as success")
                } catch is CheckFailure { throw CheckFailure(description: "System Events failure counted as success") }
                catch {
                    try require(error.localizedDescription.contains("\(code)"), "System Events error lost its code")
                    try require(error.localizedDescription.contains("Automation") == needsPermission,
                        "Automation guidance did not match the actual failure")
                }
            }
        }
    }
}
