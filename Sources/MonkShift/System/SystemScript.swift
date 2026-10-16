import AppKit
import MonkShiftCore

@MainActor enum SystemScript {
    static func run(_ statement: String) throws -> NSAppleEventDescriptor {
        let source = """
        with timeout of 5 seconds
            tell application "System Events"
                \(statement)
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else { throw MonkError("Could not create the system preference script.") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "System Events failed."
            throw MonkError("\(message) (\(number)). Check MonkShift in Privacy & Security → Automation and Accessibility.")
        }
        return result
    }
}
