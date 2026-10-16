import SwiftUI

struct ShortcutList: View {
    @ObservedObject var manager: ShortcutManager
    @State private var editing: ShortcutAction?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ShortcutAction.allCases) { action in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(action.title)
                        Spacer()
                        Text(manager.shortcuts[action]?.label ?? "Unassigned").monospaced()
                        Button("Edit…") { editing = action }.accessibilityLabel("Edit \(action.title) shortcut")
                    }
                    if let error = manager.errors[action] { Text(error).font(.callout).foregroundStyle(.red) }
                }
            }
            Text("Global shortcuts use physical letter keys (ANSI positions). If another app uses a shortcut, choose a different combination.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { action in
            ShortcutEditor(action: action, manager: manager)
        }
    }
}

struct ShortcutEditor: View {
    let action: ShortcutAction
    @ObservedObject var manager: ShortcutManager
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Shortcut
    init(action: ShortcutAction, manager: ShortcutManager) {
        self.action = action
        self.manager = manager
        _draft = State(initialValue: manager.shortcuts[action] ?? Shortcut(key: action.defaultKey))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("\(action.title) Shortcut").font(.title2.weight(.semibold))
            HStack {
                Toggle("⌃ Control", isOn: $draft.control)
                Toggle("⌥ Option", isOn: $draft.option)
                Toggle("⌘ Command", isOn: $draft.command)
                Toggle("⇧ Shift", isOn: $draft.shift)
            }
            .toggleStyle(.checkbox)
            Picker("Letter", selection: $draft.key) {
                ForEach(Shortcut.keys, id: \.0) { key in Text(key.0).tag(key.0) }
            }
            if let error = manager.errors[action] { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text(draft.label).monospaced().foregroundStyle(.secondary)
                Button("Save") {
                    manager.update(draft, for: action)
                    if manager.errors[action] == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 500)
    }
}
