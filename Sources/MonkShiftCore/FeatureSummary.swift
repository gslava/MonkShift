import Foundation

/// Summarizes observed settings, independently of any saved restore session.
public struct FeatureSummary {
    public enum Status {
        case allEnabled, partiallyEnabled, off, unknown
    }

    public let enabledCount: Int
    public let unknownCount: Int
    public let unavailableCount: Int
    public let totalCount: Int

    public init(states: [Feature: FeatureState]) {
        totalCount = Feature.allCases.count
        enabledCount = Feature.allCases.filter {
            states[$0]?.available == true && states[$0]?.enabled == true
        }.count
        unavailableCount = Feature.allCases.filter { states[$0]?.available == false }.count
        unknownCount = Feature.allCases.filter {
            states[$0] == nil || (states[$0]?.available == true && states[$0]?.enabled == nil)
        }.count
    }

    public var status: Status {
        if enabledCount == totalCount { return .allEnabled }
        if enabledCount > 0 { return .partiallyEnabled }
        if unknownCount + unavailableCount > 0 { return .unknown }
        return .off
    }

    public var title: String {
        switch status {
        case .allEnabled: return "All enabled"
        case .partiallyEnabled: return "Partially enabled"
        case .off: return "Off"
        case .unknown: return "Status unknown"
        }
    }

    public var detail: String {
        var parts = ["\(enabledCount) of \(totalCount) enabled"]
        if unknownCount > 0 { parts.append("\(unknownCount) unknown") }
        if unavailableCount > 0 { parts.append("\(unavailableCount) unavailable") }
        return parts.joined(separator: " · ")
    }
}
