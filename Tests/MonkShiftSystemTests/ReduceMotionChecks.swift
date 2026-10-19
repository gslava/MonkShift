import Foundation

enum ReduceMotionChecks {
    static func testSetAndRestore() async throws {
        for original in [false, true] {
            var state = original
            let api = ReduceMotionAPI(read: { state }, write: { state = $0 })
            let saved = api.read()
            try api.set(enabled: true)
            try require(api.read(), "Reduce Motion was not enabled")
            try api.set(enabled: false)
            try require(!api.read(), "Reduce Motion was not disabled")
            try api.set(enabled: saved)
            try require(state == original, "Reduce Motion did not restore its original state")
        }
    }

    static func testRejectedWritesAreReported() async throws {
        for original in [false, true] {
            let api = ReduceMotionAPI(read: { original }, write: { _ in })
            do {
                try api.set(enabled: !original)
            } catch {
                try require(error.localizedDescription.contains("macOS did not retain Reduce Motion"), "Rejected write lost its explanation")
                continue
            }
            throw CheckFailure(description: "Rejected Reduce Motion write was reported as success")
        }
    }
}
