import Foundation

public struct RestoreJournal: Codable, Equatable {
    public struct FocusBaseline: Codable, Equatable {
        public var stageManagerBeforeOneWindow: Data?
        public var hideRecentAppsBeforeOneWindow: Data? = nil
    }

    public var version = 1
    public var individual: [String: Data] = [:]
    public var monk: [String: Data] = [:]
    // Optional fields keep existing journals readable. The session baseline also
    // preserves an individual focus cycle when Monk Mode temporarily replaces it.
    public var stageManagerBeforeOneWindow: Data?
    public var hideRecentAppsBeforeOneWindow: Data?
    public var monkFocusBaseline: FocusBaseline?
    public init() {}
}

@MainActor public protocol RestoreStore: AnyObject {
    func load() throws -> RestoreJournal
    func save(_ journal: RestoreJournal) throws
}

@MainActor public final class FileRestoreStore: RestoreStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> RestoreJournal {
        guard FileManager.default.fileExists(atPath: url.path) else { return RestoreJournal() }
        let journal = try JSONDecoder().decode(RestoreJournal.self, from: Data(contentsOf: url))
        guard journal.version == 1 else { throw MonkError("Unsupported restore file version. Keep the file and use a compatible MonkShift version.") }
        let known = Set(Feature.allCases.map(\.rawValue))
        guard Set(journal.individual.keys).isSubset(of: known), Set(journal.monk.keys).isSubset(of: known) else {
            throw MonkError("The restore file contains unknown settings. It has been preserved.")
        }
        return journal
    }

    public func save(_ journal: RestoreJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: url, options: [.atomic])
    }
}
