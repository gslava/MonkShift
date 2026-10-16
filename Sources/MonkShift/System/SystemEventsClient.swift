import Foundation
import Carbon
import MonkShiftCore

/// Sends the same preferences requests as System Events' scripting dictionary,
/// without compiling scripts or blocking the main actor. Descriptors stay on one queue.
final class SystemEventsClient: @unchecked Sendable {
    enum Setting: UInt32, Sendable {
        case hideDock = 0x64616864 // dahd
        case hideMenuBar = 0x6461686D // dahm
    }

    typealias Transport = @Sendable (NSAppleEventDescriptor, TimeInterval) throws -> NSAppleEventDescriptor
    private let queue = DispatchQueue(label: "app.monkshift.system-events", qos: .userInitiated)
    private let transport: Transport
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 5, transport: @escaping Transport = { event, timeout in
        try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
    }) {
        self.timeout = timeout
        self.transport = transport
    }

    func read(_ setting: Setting) async throws -> Bool {
        try await request(setting, value: nil)
    }

    func write(_ setting: Setting, enabled: Bool) async throws {
        _ = try await request(setting, value: enabled)
    }

    private func request(_ setting: Setting, value: Bool?) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let result = try autoreleasepool { () throws -> Bool in
                        let event = Self.event(setting, value: value)
                        let reply: NSAppleEventDescriptor
                        do { reply = try transport(event, timeout) }
                        catch {
                            let error = error as NSError
                            throw MonkError("System Events request failed (\(error.code)): \(error.localizedDescription). Check MonkShift under Privacy & Security → Automation.")
                        }
                        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
                            let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue ?? "System Events failed."
                            throw MonkError("\(message) (\(error.int32Value)). Check MonkShift under Privacy & Security → Automation.")
                        }
                        if value != nil { return true }
                        guard let data = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
                              let boolean = data.coerce(toDescriptorType: DescType(typeBoolean)) else {
                            throw MonkError("System Events returned an unknown setting value. No enabled/disabled state was inferred.")
                        }
                        return boolean.booleanValue
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func event(_ setting: Setting, value: Bool?) -> NSAppleEventDescriptor {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
            eventID: value == nil ? AEEventID(kAEGetData) : AEEventID(kAESetData), targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let dock = property(0x64706173, container: .null()) // dpas: application's dock preferences
        event.setParam(property(setting.rawValue, container: dock), forKeyword: AEKeyword(keyDirectObject))
        if let value { event.setParam(NSAppleEventDescriptor(boolean: value), forKeyword: AEKeyword(keyAEData)) }
        return event
    }

    private static func property(_ code: UInt32, container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier))!
    }
}
