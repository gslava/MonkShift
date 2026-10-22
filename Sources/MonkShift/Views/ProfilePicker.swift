import SwiftUI

struct ProfilePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.profiles) { profile in
                Button { model.selectProfile(id: profile.id) } label: {
                    if profile.id == model.selectedProfileID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button("New Profile…") { model.showNewProfile = true }
                .disabled(!model.canCreateProfile)
        } label: {
            Text("Profile: \(model.selectedProfileName)").lineLimit(1).truncationMode(.middle)
        }
        .frame(width: 220)
        .disabled(!model.canSelectProfile)
        .accessibilityLabel("Settings profile")
        .accessibilityValue(model.selectedProfileName)
    }
}

struct NewProfileView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Profile").font(.title2.weight(.semibold))
            Text("Copy the settings from “\(model.selectedProfileName)”. Changes to the new profile are saved automatically.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Profile name", text: $name).focused($nameFocused)
                .onSubmit { create() }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { create() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canCreateProfile)
            }
        }
        .padding(24).frame(width: 380)
        .onAppear { nameFocused = true }
    }

    private func create() {
        do { try model.createProfile(name: name); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
