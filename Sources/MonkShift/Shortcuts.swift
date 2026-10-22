import AppKit
import Carbon
import MonkShiftCore

enum ShortcutAction: UInt32, CaseIterable, Identifiable, Codable {
    case monk = 1, stage, grayscale, menuBar, oneWindow, dimming
    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .monk: return "Monk Mode"
        case .stage: return "Stage Manager"
        case .grayscale: return "Color Filter"
        case .menuBar: return "Hide / show menu bar"
        case .oneWindow: return "Show windows one at a time"
        case .dimming: return "Dim background windows"
        }
    }
    var defaultKey: String {
        switch self {
        case .monk: return "M"; case .stage: return "S"; case .grayscale: return "C"; case .menuBar: return "B"
        case .oneWindow: return "W"; case .dimming: return "D"
        }
    }
    var feature: Feature? {
        switch self {
        case .monk: return nil; case .stage: return .stageManager; case .grayscale: return .grayscale; case .menuBar: return .hideMenuBar
        case .oneWindow: return .oneWindowAtATime; case .dimming: return .dimBackground
        }
    }
}

struct Shortcut: Codable, Equatable {
    var key: String
    var control = true
    var option = true
    var command = true
    var shift = false
    var modifiers: UInt32 {
        (control ? UInt32(controlKey) : 0) | (option ? UInt32(optionKey) : 0) |
        (command ? UInt32(cmdKey) : 0) | (shift ? UInt32(shiftKey) : 0)
    }
    var label: String { "\(control ? "⌃" : "")\(option ? "⌥" : "")\(shift ? "⇧" : "")\(command ? "⌘" : "")\(key)" }
    // Physical ANSI keys, independent of the currently selected input language.
    static let keys: [(String, UInt32)] = [
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4),
        ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35),
        ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6)
    ]
    var keyCode: UInt32? { Self.keys.first { $0.0 == key }?.1 }
}

@MainActor final class ShortcutManager: ObservableObject {
    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]
    @Published private(set) var errors: [ShortcutAction: String] = [:]
    var onAction: ((ShortcutAction) -> Void)?
    private var references: [ShortcutAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var active = false
    private let defaults: UserDefaults

    init(installHandler: Bool = true, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: "shortcuts")
            .flatMap { try? JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]
        for action in ShortcutAction.allCases {
            var shortcut = saved[String(action.rawValue)] ?? Shortcut(key: action.defaultKey)
            if saved[String(action.rawValue)] == nil && (action == .oneWindow || action == .dimming) {
                // A new default must not invalidate an existing custom binding.
                let candidates = [Shortcut(key: action.defaultKey), Shortcut(key: action.defaultKey, shift: true)] +
                    Shortcut.keys.map { Shortcut(key: $0.0) }
                shortcut = candidates.first { !shortcuts.values.contains($0) && !saved.values.contains($0) } ?? shortcut
            }
            shortcuts[action] = shortcut
        }
        guard installHandler else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x4D4F4E4B,
                  let action = ShortcutAction(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(context).takeUnretainedValue()
            // Carbon dispatches app event handlers on the main thread.
            MainActor.assumeIsolated { manager.onAction?(action) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr {
            for action in ShortcutAction.allCases { errors[action] = "Could not install global shortcut handler (\(status))." }
        }
    }

    func activate() {
        guard !active, handler != nil else { return }
        active = true
        for action in ShortcutAction.allCases {
            do { try register(shortcuts[action]!, for: action) }
            catch { errors[action] = error.localizedDescription }
        }
    }

    func deactivate() {
        active = false
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
    }

    private func register(_ shortcut: Shortcut, for action: ShortcutAction) throws {
        guard handler != nil else { throw MonkError("The global shortcut handler is unavailable.") }
        guard let key = shortcut.keyCode, shortcut.control || shortcut.command || shortcut.option else {
            throw MonkError("Choose a letter and at least one of Control, Option, or Command.")
        }
        guard !shortcuts.contains(where: { $0.key != action && $0.value == shortcut }) else {
            throw MonkError("This shortcut is already assigned to another MonkShift action.")
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x4D4F4E4B, id: action.rawValue)
        let status = RegisterEventHotKey(key, shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { throw MonkError("Shortcut is unavailable or used by another app (\(status)). Choose another combination.") }
        if let previous = references[action] { UnregisterEventHotKey(previous) }
        references[action] = reference
        errors.removeValue(forKey: action)
    }

    func update(_ shortcut: Shortcut, for action: ShortcutAction) {
        do {
            guard active else { throw MonkError("Grant Automation permission before editing global shortcuts.") }
            if shortcut != shortcuts[action] || references[action] == nil { try register(shortcut, for: action) }
            shortcuts[action] = shortcut
            let values = shortcuts.reduce(into: [String: Shortcut]()) { $0[String($1.key.rawValue)] = $1.value }
            defaults.set(try JSONEncoder().encode(values), forKey: "shortcuts")
            errors.removeValue(forKey: action)
        } catch { errors[action] = error.localizedDescription }
    }

    func shutdown() { deactivate(); if let handler { RemoveEventHandler(handler) }; handler = nil }
}
