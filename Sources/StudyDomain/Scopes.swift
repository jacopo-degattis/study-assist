import Foundation

/// Identifies a resolved, confirmed study scope inside one document snapshot.
public struct ScopeID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

/// The immutable, allowlisted set of passages a session may use.
///
/// A scope always names one document snapshot. Questions, rubrics, hints and
/// assessments generated inside it may cite only these chunk ids.
public struct StudyScope: Codable, Hashable, Sendable, Identifiable {
    public var id: ScopeID
    public var snapshotId: SnapshotID
    /// The student's own wording. Empty for the whole document.
    public var query: String
    public var title: String
    public var matchedChunkIds: [ChunkID]
    public var isFullDocument: Bool
    public var version: Int
    public var confirmedByUser: Bool
    public var createdAt: Date

    public init(
        id: ScopeID = ScopeID(),
        snapshotId: SnapshotID,
        query: String,
        title: String,
        matchedChunkIds: [ChunkID],
        isFullDocument: Bool,
        version: Int,
        confirmedByUser: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.snapshotId = snapshotId
        self.query = query
        self.title = title
        self.matchedChunkIds = matchedChunkIds
        self.isFullDocument = isFullDocument
        self.version = version
        self.confirmedByUser = confirmedByUser
        self.createdAt = createdAt
    }

    public var displayTitle: String {
        isFullDocument ? "Entire document" : (title.isEmpty ? query : title)
    }
}

/// One passage that matched the student's topic request.
public struct ScopeMatch: Codable, Hashable, Sendable, Identifiable {
    public var chunkId: ChunkID
    public var score: Double
    public var sectionTitle: String
    public var location: SourceLocation
    public var excerpt: String

    public var id: String { chunkId.rawValue }

    public init(chunkId: ChunkID, score: Double, sectionTitle: String, location: SourceLocation, excerpt: String) {
        self.chunkId = chunkId
        self.score = score
        self.sectionTitle = sectionTitle
        self.location = location
        self.excerpt = excerpt
    }
}

public enum ScopeResolutionState: String, Sendable, Codable {
    case found
    case ambiguous
    case notFound
    case fullDocument

    public var requiresConfirmation: Bool { self == .ambiguous }
}

/// The deterministic result of searching one snapshot for a topic request.
/// Produced locally; no model is involved, so the app can refuse honestly.
public struct ScopeResolution: Sendable, Hashable {
    public var query: String
    public var snapshotId: SnapshotID
    public var state: ScopeResolutionState
    public var matches: [ScopeMatch]
    public var suggestedChunkIds: [ChunkID]
    public var sectionTitles: [String]
    public var message: String?

    public init(
        query: String,
        snapshotId: SnapshotID,
        state: ScopeResolutionState,
        matches: [ScopeMatch] = [],
        suggestedChunkIds: [ChunkID] = [],
        sectionTitles: [String] = [],
        message: String? = nil
    ) {
        self.query = query
        self.snapshotId = snapshotId
        self.state = state
        self.matches = matches
        self.suggestedChunkIds = suggestedChunkIds
        self.sectionTitles = sectionTitles
        self.message = message
    }

    public static let notFoundMessage = "This topic was not found in the uploaded document."
}

/// A suggestion taken from the document's own structure.
public struct ScopeSuggestion: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case section
        case topic
    }

    public var title: String
    public var kind: Kind
    public var chunkIds: [ChunkID]

    public var id: String { "\(kind.rawValue):\(title)" }

    public init(title: String, kind: Kind, chunkIds: [ChunkID]) {
        self.title = title
        self.kind = kind
        self.chunkIds = chunkIds
    }
}
