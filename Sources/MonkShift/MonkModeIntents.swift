import AppIntents
import MonkShiftCore

enum MonkModeCommand {
    case toggle, enable, disable
}

/// Intents run in the foreground app, which owns the single-instance lock and journal.
@MainActor final class MonkModeIntentHandler {
    static let shared = MonkModeIntentHandler()
    weak var model: AppModel?

    func perform(_ command: MonkModeCommand) async throws {
        guard let model else { throw MonkError("MonkShift is still starting. Try the shortcut again.") }
        try await model.performMonkMode(command)
    }
}

struct ToggleMonkModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Monk Mode"
    static let description = IntentDescription("Enable Monk Mode, or restore the previous settings if a Monk session is saved.")
    static let openAppWhenRun = true
    static var parameterSummary: some ParameterSummary { Summary("Toggle Monk Mode") }

    @MainActor func perform() async throws -> some IntentResult {
        try await MonkModeIntentHandler.shared.perform(.toggle)
        return .result()
    }
}

struct EnableMonkModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Enable Monk Mode"
    static let description = IntentDescription("Apply Monk Mode while preserving the settings saved before the session.")
    static let openAppWhenRun = true
    static var parameterSummary: some ParameterSummary { Summary("Enable Monk Mode") }

    @MainActor func perform() async throws -> some IntentResult {
        try await MonkModeIntentHandler.shared.perform(.enable)
        return .result()
    }
}

struct DisableMonkModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Disable Monk Mode"
    static let description = IntentDescription("Restore the settings saved before Monk Mode. Failed restores remain available for retry.")
    static let openAppWhenRun = true
    static var parameterSummary: some ParameterSummary { Summary("Disable Monk Mode") }

    @MainActor func perform() async throws -> some IntentResult {
        try await MonkModeIntentHandler.shared.perform(.disable)
        return .result()
    }
}

struct MonkShiftAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleMonkModeIntent(), phrases: ["Toggle Monk Mode in \(.applicationName)"],
            shortTitle: "Toggle Monk Mode", systemImageName: "switch.2")
        AppShortcut(intent: EnableMonkModeIntent(), phrases: ["Enable Monk Mode in \(.applicationName)"],
            shortTitle: "Enable Monk Mode", systemImageName: "moon.fill")
        AppShortcut(intent: DisableMonkModeIntent(), phrases: ["Disable Monk Mode in \(.applicationName)"],
            shortTitle: "Disable Monk Mode", systemImageName: "arrow.uturn.backward")
    }
}
