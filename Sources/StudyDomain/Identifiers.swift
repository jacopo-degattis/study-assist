import Foundation

/// Strongly typed identifiers for every persisted entity.
///
/// All identifiers are UUID strings. Typed wrappers keep documents, snapshots,
/// chunks and questions from being mixed up in call sites and in prompt JSON.
public struct DocumentID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

public struct SnapshotID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

public struct SectionID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

public struct ChunkID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

public struct TopicID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

public struct SessionID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

public struct QuestionID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

public struct AttemptID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

public struct EvaluationID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

public struct PromptVersionID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

public struct ProviderProfileID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

public struct SpeechProfileID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}
