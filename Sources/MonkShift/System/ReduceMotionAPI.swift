import Darwin
import MonkShiftCore

/// Version-sensitive system setters stay isolated from the settings engine.
final class ReduceMotionAPI {
    private let handle: UnsafeMutableRawPointer?
    private let getEnabled: () -> Bool
    private let setEnabled: (Bool) -> Void

    init() throws {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY) else {
            throw MonkError("The system Reduce Motion API is unavailable.")
        }
        guard let getter = dlsym(handle, "_AXInterfaceGetReduceMotionEnabled"),
              let setter = dlsym(handle, "_AXInterfaceSetReduceMotionEnabled") else {
            dlclose(handle)
            throw MonkError("This macOS version does not expose the Reduce Motion controls.")
        }
        let read = unsafeBitCast(getter, to: (@convention(c) () -> Bool).self)
        let write = unsafeBitCast(setter, to: (@convention(c) (Bool) -> Void).self)
        self.handle = handle
        getEnabled = { read() }
        setEnabled = { write($0) }
    }

    /// Fake accessors let checks exercise rejected writes without changing macOS.
    init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
        handle = nil
        getEnabled = read
        setEnabled = write
    }

    deinit { if let handle { dlclose(handle) } }

    func read() -> Bool { getEnabled() }

    func set(enabled: Bool) throws {
        setEnabled(enabled)
        guard getEnabled() == enabled else {
            throw MonkError("macOS did not retain Reduce Motion. The previous state is saved for restoration.")
        }
    }
}
