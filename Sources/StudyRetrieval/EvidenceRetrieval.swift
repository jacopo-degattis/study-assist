import Foundation
import StudyDomain

/// Retrieves evidence only from one snapshot. Every returned chunk is checked
/// against the requested snapshot and must be usable as evidence.
public struct LocalEvidenceRetriever: EvidenceRetriever {
    private let repository: StudyRepository

    public init(repository: StudyRepository) {
        self.repository = repository
    }

    public func evidence(for topic: Topic, in snapshotId: SnapshotID) async throws -> [SourceChunk] {
        try await evidence(forChunkIds: topic.sourceChunkIds, in: snapshotId)
    }

    public func evidence(forChunkIds ids: [ChunkID], in snapshotId: SnapshotID) async throws -> [SourceChunk] {
        guard !ids.isEmpty else { return [] }
        let chunks = try await repository.chunks(ids: ids)
        let byId = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
        // Preserve the caller's order, drop foreign or unusable passages.
        return ids.compactMap { byId[$0] }
            .filter { $0.snapshotId == snapshotId && $0.isUsableAsEvidence }
    }

    public func search(_ query: String, in snapshotId: SnapshotID, limit: Int) async throws -> [SourceChunk] {
        guard limit > 0 else { return [] }
        let fullTextIds = try await repository.searchChunkIds(query: query, snapshotId: snapshotId, limit: limit)
        if !fullTextIds.isEmpty {
            let chunks = try await evidence(forChunkIds: fullTextIds, in: snapshotId)
            if !chunks.isEmpty {
                return Array(chunks.prefix(limit))
            }
        }
        // Deterministic lexical fallback: no FTS5, or no matches.
        let all = try await repository.chunks(snapshotId: snapshotId).filter(\.isUsableAsEvidence)
        let scored = all.compactMap { chunk -> (SourceChunk, Double)? in
            let score = TextUtilities.containment(of: query, in: chunk.text)
            return score > 0 ? (chunk, score) : nil
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.order < rhs.0.order
            }
            .prefix(limit)
            .map(\.0)
    }
}

/// Builds topics deterministically from document structure and passages.
///
/// No LLM is involved, so a topic can never mention material that is absent
/// from the snapshot. Every topic references real, usable chunks.
public enum TopicCatalogBuilder {
    public struct Configuration: Sendable {
        public var chunksPerTopic: Int
        public var minimumTopicTitleLength: Int

        public init(chunksPerTopic: Int = 2, minimumTopicTitleLength: Int = 3) {
            self.chunksPerTopic = chunksPerTopic
            self.minimumTopicTitleLength = minimumTopicTitleLength
        }

        public static let `default` = Configuration()
    }

    public static func buildTopics(
        snapshotId: SnapshotID,
        sections: [DocumentSection],
        chunks: [SourceChunk],
        configuration: Configuration = .default
    ) -> [Topic] {
        let usable = chunks.filter(\.isUsableAsEvidence).sorted { $0.order < $1.order }
        guard !usable.isEmpty else { return [] }

        let sectionById = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        var grouped: [(title: String, section: DocumentSection?, chunks: [SourceChunk])] = []

        // Group chunks by the section they start in, preserving order.
        var currentSectionId: SectionID?
        var buffer: [SourceChunk] = []
        var currentSection: DocumentSection?

        func flush() {
            guard !buffer.isEmpty else { return }
            let title = topicTitle(for: buffer, section: currentSection)
            grouped.append((title: title, section: currentSection, chunks: buffer))
            buffer = []
        }

        for chunk in usable {
            if let sectionId = chunk.sectionId, sectionId != currentSectionId {
                flush()
                currentSectionId = sectionId
                currentSection = sectionById[sectionId]
            }
            buffer.append(chunk)
            if buffer.count >= max(1, configuration.chunksPerTopic) {
                flush()
            }
        }
        flush()

        var topics: [Topic] = []
        for (index, group) in grouped.enumerated() {
            var title = group.title
            if title.count < configuration.minimumTopicTitleLength {
                title = "Passage \(index + 1)"
            }
            topics.append(
                Topic(
                    snapshotId: snapshotId,
                    title: title,
                    sourceChunkIds: group.chunks.map(\.id),
                    order: index
                )
            )
        }
        return topics
    }

    /// Ensures the snapshot has a topic catalog, building it locally if needed.
    /// Used both when a session starts and as soon as a document becomes ready,
    /// so the ready screen never blocks a document that has usable passages.
    @discardableResult
    public static func ensureTopics(
        repository: any StudyRepository,
        snapshotId: SnapshotID
    ) async throws -> [Topic] {
        let existing = try await repository.topics(snapshotId: snapshotId)
        if !existing.isEmpty { return existing }
        let sections = try await repository.sections(snapshotId: snapshotId)
        let chunks = try await repository.chunks(snapshotId: snapshotId)
        let built = buildTopics(snapshotId: snapshotId, sections: sections, chunks: chunks)
        if !built.isEmpty {
            try await repository.saveTopics(built)
        }
        return built
    }

    /// A title taken from the document itself: the section heading when it is a
    /// real heading, otherwise the first meaningful words of the first passage.
    static func topicTitle(for chunks: [SourceChunk], section: DocumentSection?) -> String {
        if let section, !section.title.hasPrefix("Page "), section.title != "Document", section.title.count >= 3 {
            return section.title
        }
        guard let first = chunks.first else { return "Passage" }
        let candidates = first.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for candidate in candidates {
            if HeadingHeuristics.looksLikeHeading(candidate), candidate.count >= 3 {
                return String(candidate.prefix(120))
            }
        }
        return HeadingHeuristics.titleFromText(first.text)
    }
}
