import Foundation

public struct ProfileSettings: Codable, Equatable, Sendable {
    public var values: [Feature: Bool]
    public var intensity: Double
    public var dimmingIntensity: Double
    public var focusMode: Feature

    public init(values: [Feature: Bool], intensity: Double, dimmingIntensity: Double, focusMode: Feature) {
        self.values = values
        self.intensity = intensity
        self.dimmingIntensity = dimmingIntensity
        self.focusMode = focusMode
    }

    public var normalized: ProfileSettings {
        var result = self
        if result.values[.oneWindowAtATime] == true && result.values[.dimBackground] == true {
            result.values[focusMode.alternativeFocusMode ?? .dimBackground] = false
        }
        if result.values[.oneWindowAtATime] == true {
            result.focusMode = .oneWindowAtATime
            result.values[.stageManager] = true
            // Default new one-window profiles to hidden recent apps, but retain
            // an explicit choice saved through the independent checkbox.
            if result.values[.hideRecentApps] == nil { result.values[.hideRecentApps] = true }
        } else if result.values[.dimBackground] == true {
            result.focusMode = .dimBackground
        }
        return result
    }

    public func validate() throws {
        guard intensity.isFinite, (0...1).contains(intensity),
              dimmingIntensity.isFinite, (0...0.9).contains(dimmingIntensity),
              focusMode == .oneWindowAtATime || focusMode == .dimBackground else {
            throw MonkError("The profile contains unsupported settings. Its file has been preserved.")
        }
    }
}

public struct SettingsProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var settings: ProfileSettings

    public init(id: String, name: String, settings: ProfileSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }
}

public struct ProfileLibrary: Codable, Equatable {
    public var version = 1
    public var profiles: [SettingsProfile]
    public var selectedID: String
    public var selected: SettingsProfile { profiles.first { $0.id == selectedID }! }

    public init(settings: ProfileSettings) {
        profiles = [SettingsProfile(id: "default", name: "Default", settings: settings)]
        selectedID = "default"
    }

    public mutating func add(name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else { throw MonkError("Enter a profile name between 1 and 64 characters.") }
        guard !profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw MonkError("A profile with this name already exists.")
        }
        let profile = SettingsProfile(id: UUID().uuidString, name: name, settings: selected.settings)
        profiles.append(profile)
        selectedID = profile.id
    }

    public mutating func update(_ settings: ProfileSettings, for id: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].settings = settings
    }

    public func validate() throws {
        guard version == 1, !profiles.isEmpty,
              profiles.contains(where: { $0.id == "default" && $0.name == "Default" }),
              profiles.contains(where: { $0.id == selectedID }),
              Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map { $0.name.lowercased() }).count == profiles.count,
              profiles.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 64 }) else {
            throw MonkError("The profiles file is unsupported or invalid. It has been preserved.")
        }
        for profile in profiles { try profile.settings.validate() }
    }
}

@MainActor public protocol ProfileStore: AnyObject {
    func load() throws -> ProfileLibrary?
    func save(_ library: ProfileLibrary) throws
}

@MainActor public final class FileProfileStore: ProfileStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> ProfileLibrary? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let library = try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: url))
        try library.validate()
        return library
    }

    public func save(_ library: ProfileLibrary) throws {
        try library.validate()
        let data = try JSONEncoder().encode(library)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
