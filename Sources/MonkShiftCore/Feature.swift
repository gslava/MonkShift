import Foundation

public enum Feature: String, CaseIterable, Codable, Identifiable {
    case instantDock, hideDock, hideMenuBar, instantMenuBar
    case stageManager, hideRecentApps, oneWindowAtATime, blackWallpaper, grayscale

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .instantDock: return "Instant Dock animations"
        case .hideDock: return "Automatically hide Dock"
        case .hideMenuBar: return "Automatically hide menu bar"
        case .instantMenuBar: return "Instant menu bar animation"
        case .stageManager: return "Stage Manager"
        case .hideRecentApps: return "Hide recent apps in Stage Manager"
        case .oneWindowAtATime: return "Show windows one at a time"
        case .blackWallpaper: return "Pure black wallpaper"
        case .grayscale: return "Grayscale color filter"
        }
    }
}

public struct FeatureState {
    /// nil means unknown or unavailable, never an inferred success.
    public var enabled: Bool?
    public var detail: String?
    public var available: Bool
    public init(enabled: Bool?, detail: String? = nil, available: Bool = true) {
        self.enabled = enabled
        self.detail = detail
        self.available = available
    }
}

public struct OperationIssue: Identifiable {
    public var id: String { feature.rawValue }
    public let feature: Feature
    public let message: String
    public init(_ feature: Feature, _ error: Error) {
        self.feature = feature
        self.message = error.localizedDescription
    }
}

public struct MonkError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@MainActor public protocol SettingsBackend: AnyObject {
    func read(_ feature: Feature) throws -> FeatureState
    func snapshot(_ feature: Feature) throws -> Data
    func apply(_ feature: Feature, intensity: Double) throws
    func disable(_ feature: Feature) throws
    func restore(_ feature: Feature, from data: Data) throws
    func finishChanges() throws
}
