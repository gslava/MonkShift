import Foundation
import Darwin

/// The descriptor stays open for the owner's lifetime; the OS releases it on exit/crash.
final class SingleInstanceLock {
    enum Acquisition {
        case acquired(SingleInstanceLock)
        case alreadyRunning(pid_t?)
    }

    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    static func acquire(directory: URL) throws -> Acquisition {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("instance.lock")
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw failure("open", code: errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            let pid = processID(descriptor)
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { return .alreadyRunning(pid) }
            throw failure("lock", code: code)
        }
        let lock = SingleInstanceLock(descriptor: descriptor)
        let data = Data("\(getpid())\n".utf8)
        guard ftruncate(descriptor, 0) == 0 else { throw failure("write", code: errno) }
        let count = data.withUnsafeBytes { Darwin.pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw failure("write", code: errno) }
        return .acquired(lock)
    }

    private static func processID(_ descriptor: Int32) -> pid_t? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = bytes.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count > 0, let pid = Int32(String(decoding: bytes.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    private static func failure(_ operation: String, code: Int32) -> NSError {
        NSError(domain: "MonkShift.SingleInstance", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "Could not \(operation) the application lock: \(String(cString: strerror(code))). No settings were changed."
        ])
    }
}
