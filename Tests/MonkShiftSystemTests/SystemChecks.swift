import Foundation
import Darwin

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

@main enum SystemChecks {
    static func main() async {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("--probe-lock") {
            do {
                switch try SingleInstanceLock.acquire(directory: URL(fileURLWithPath: CommandLine.arguments[2])) {
                case .alreadyRunning: exit(73)
                case .acquired(let lock):
                    withExtendedLifetime(lock) {
                        if CommandLine.arguments[1] == "--probe-lock-crash" { raise(SIGKILL) }
                        exit(0)
                    }
                }
            } catch { exit(74) }
        }
        let tests: [(String, () async throws -> Void)] = [
            ("File lock excludes a second process", testLockExclusion),
            ("File lock is released after normal exit", testLockRelease),
            ("File lock is released after a crash", testLockCrashRelease),
            ("Lock file errors fail closed", testLockFailure),
            ("Typed Dock/menu bar events preserve values", SystemEventsChecks.testTypedEvents),
            ("Read/write commands match the macOS scripting dictionary", SystemEventsChecks.testCommandsMatchScriptingDictionary),
            ("Slow system reply leaves main actor responsive", { try await SystemEventsChecks.testMainActorRemainsResponsive() }),
            ("System event transport is serialized", SystemEventsChecks.testTransportIsSerialized),
            ("Unknown, denied and timed out replies fail honestly", SystemEventsChecks.testUnknownAndErrorRepliesAreRejected),
            ("Reduce Motion restores enabled and disabled baselines", ReduceMotionChecks.testSetAndRestore),
            ("Rejected Reduce Motion writes are reported", ReduceMotionChecks.testRejectedWritesAreReported),
            ("Window grouping reads native modes and rejects unknown values", WindowGroupingChecks.testObservedModes),
            ("Window grouping enables one window and disables to all windows", WindowGroupingChecks.testEnableAndDisable),
            ("Rejected window grouping writes are reported", WindowGroupingChecks.testRejectedWrites),
            ("Window grouping restores exact values and absence", WindowGroupingChecks.testExactRestoration),
            ("One-window dimming conflicts require Stage Manager", WindowGroupingChecks.testActiveModeRequiresStageManager),
            ("Focus cycles preserve native grouping and prerequisite baselines", { try await WindowGroupingChecks.testFocusCycleAndRestoreAll() }),
            ("One-window profiles retain explicit native recent-app visibility", { try await WindowGroupingChecks.testProfilePreservesRecentAppsChoice() }),
            ("Desktop visibility reports complete and mixed states", DesktopVisibilityChecks.testObservedVisibility),
            ("Desktop visibility restores exact preference values and absence", DesktopVisibilityChecks.testExactPreferenceRestoration),
            ("Desktop visibility can show icons and widgets in both modes", DesktopVisibilityChecks.testDisableShowsBothModes),
            ("Rejected desktop visibility writes fail honestly", DesktopVisibilityChecks.testRejectedWrites),
            ("Desktop visibility session recovery survives partial restore and restart", { try await DesktopVisibilityChecks.testSessionRestartRecovery() })
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count) system checks, \(failures) failures. Isolated files/processes only; no macOS setting changes.")
        if failures > 0 { exit(1) }
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MonkShiftChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func child(_ mode: String, directory: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = [mode, directory.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process
    }

    private static func testLockExclusion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .acquired(let lock) = try SingleInstanceLock.acquire(directory: directory) else {
            throw CheckFailure(description: "First instance did not acquire its lock")
        }
        try withExtendedLifetime(lock) {
            let second = try child("--probe-lock", directory: directory)
            try require(second.terminationStatus == 73, "Second process accessed the protected directory")
        }
    }

    private static func testLockRelease() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try child("--probe-lock", directory: directory)
        try require(first.terminationStatus == 0, "First process failed")
        guard case .acquired(let lock) = try SingleInstanceLock.acquire(directory: directory) else {
            throw CheckFailure(description: "Stale PID prevented a subsequent launch")
        }
        withExtendedLifetime(lock) {}
    }

    private static func testLockCrashRelease() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try child("--probe-lock-crash", directory: directory)
        try require(first.terminationReason == .uncaughtSignal, "Crash probe did not terminate as intended")
        guard case .acquired(let lock) = try SingleInstanceLock.acquire(directory: directory) else {
            throw CheckFailure(description: "Crash left an unrecoverable lock")
        }
        withExtendedLifetime(lock) {}
    }

    private static func testLockFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("original")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("instance.lock"), withDestinationURL: target)
        do {
            _ = try SingleInstanceLock.acquire(directory: directory)
            throw CheckFailure(description: "Symlink unexpectedly accepted")
        } catch is CheckFailure { throw CheckFailure(description: "Symlink unexpectedly accepted") }
        catch { /* Expected: the lock must never truncate a symlink target. */ }
        try require(try String(contentsOf: target, encoding: .utf8) == "untouched", "Lock modified a symlink target")
    }
}
