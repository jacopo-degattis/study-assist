import Foundation
import StudyDomain

/// Maps a free-text topic request to a confirmed scope of real passages.
///
/// Matching is deterministic and local. It searches only the snapshot's stored
/// chunks, so a topic that is absent cannot be "found" by the model.
public struct StudyScopeResolver: Sendable {
    private let repository: any StudyRepository

    public init(repository: any StudyRepository) {
        self.repository = repository
    }

    // MARK: Suggestions

    /// Document-derived suggestions: real section titles and topic titles.
    public func suggestions(snapshotId: SnapshotID, limit: Int = 8) async throws -> [ScopeSuggestion] {
        let sections = try await repository.sections(snapshotId: snapshotId)
        let chunks = try await repository.chunks(snapshotId: snapshotId).filter(\.isUsableAsEvidence)
        let topics = try await repository.topics(snapshotId: snapshotId)

        var suggestions: [ScopeSuggestion] = []
        var seen: Set<String> = []

        for section in sections {
            let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isMeaningfulTitle(title) else { continue }
            let sectionChunks = chunks.filter { $0.sectionId == section.id }
            guard !sectionChunks.isEmpty else { continue }
            let key = TextUtilities.normalizeForComparison(title)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            suggestions.append(
                ScopeSuggestion(title: title, kind: .section, chunkIds: sectionChunks.map(\.id))
            )
        }

        for topic in topics {
            let title = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isMeaningfulTitle(title) else { continue }
            let key = TextUtilities.normalizeForComparison(title)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let ids = topic.sourceChunkIds.filter { id in chunks.contains { $0.id == id } }
            guard !ids.isEmpty else { continue }
            suggestions.append(ScopeSuggestion(title: title, kind: .topic, chunkIds: ids))
        }

        return Array(suggestions.prefix(limit))
    }

    private func isMeaningfulTitle(_ title: String) -> Bool {
        guard title.count >= 3 else { return false }
        if title.hasPrefix("Page ") { return false }
        if title == "Document" || title == "Notes" { return false }
        return true
    }

    // MARK: Resolution

    public func resolve(query: String, snapshotId: SnapshotID, maximumChunks: Int = 16) async throws -> ScopeResolution {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let chunks = try await repository.chunks(snapshotId: snapshotId).filter(\.isUsableAsEvidence)
        guard !chunks.isEmpty else {
            return ScopeResolution(
                query: trimmed,
                snapshotId: snapshotId,
                state: .notFound,
                message: "This document has no reliable passages to study."
            )
        }
        let sections = try await repository.sections(snapshotId: snapshotId)
        return ScopeMatcher.evaluate(
            query: trimmed,
            snapshotId: snapshotId,
            chunks: chunks,
            sections: sections,
            maximumChunks: maximumChunks
        )
    }

    /// Builds the full-document scope used when the student chooses no focus.
    public func fullDocumentScope(snapshotId: SnapshotID) async throws -> StudyScope {
        let chunks = try await repository.chunks(snapshotId: snapshotId).filter(\.isUsableAsEvidence)
        guard !chunks.isEmpty else {
            throw AppError.insufficientEvidence("This document has no reliable passages to study.")
        }
        return try await makeScope(
            query: "",
            snapshotId: snapshotId,
            chunkIds: chunks.map(\.id),
            title: "Entire document",
            isFullDocument: true,
            confirmedByUser: true
        )
    }

    /// Persists a scope. Only chunk ids that exist in this snapshot and are
    /// usable as evidence are ever accepted.
    public func makeScope(
        query: String,
        snapshotId: SnapshotID,
        chunkIds: [ChunkID]?,
        title: String? = nil,
        isFullDocument: Bool = false,
        confirmedByUser: Bool
    ) async throws -> StudyScope {
        let usable = try await repository.chunks(snapshotId: snapshotId).filter(\.isUsableAsEvidence)
        guard !usable.isEmpty else {
            throw AppError.insufficientEvidence("This document has no reliable passages to study.")
        }
        let usableIds = Set(usable.map(\.id))
        let requested = chunkIds.map { ids in ids.filter { usableIds.contains($0) } } ?? usable.map(\.id)
        let selectedSet = Set(requested)
        let ordered = usable.map(\.id).filter { selectedSet.contains($0) }
        guard !ordered.isEmpty else {
            throw AppError.insufficientEvidence("The selected focus has no reliable passages.")
        }

        let trimmedQuery = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let full = isFullDocument || selectedSet == usableIds
        let resolvedTitle: String
        if full {
            resolvedTitle = "Entire document"
        } else if let title, !title.isEmpty {
            resolvedTitle = String(title.prefix(120))
        } else {
            resolvedTitle = String(trimmedQuery.prefix(120))
        }

        let existing = try await repository.scopes(snapshotId: snapshotId)
        let scope = StudyScope(
            snapshotId: snapshotId,
            query: trimmedQuery,
            title: resolvedTitle,
            matchedChunkIds: ordered,
            isFullDocument: full,
            version: existing.count + 1,
            confirmedByUser: confirmedByUser
        )
        try await repository.saveScope(scope)
        return scope
    }

    /// The passages a scope authorizes, in document order.
    public func authorizedChunks(scope: StudyScope) async throws -> [SourceChunk] {
        let chunks = try await repository.chunks(ids: scope.matchedChunkIds)
        return chunks
            .filter { $0.snapshotId == scope.snapshotId && $0.isUsableAsEvidence }
            .sorted { $0.order < $1.order }
    }
}

// MARK: - Deterministic matcher

public enum ScopeMatcher {
    public struct Input: Sendable {
        public var chunk: SourceChunk
        public var sectionTitle: String

        public init(chunk: SourceChunk, sectionTitle: String) {
            self.chunk = chunk
            self.sectionTitle = sectionTitle
        }
    }

    /// Thresholds are explicit and testable, not tuned claims.
    public struct Thresholds: Sendable {
        public var minimumChunkScore: Double
        public var foundScore: Double
        public var ambiguityGap: Double
        public var minimumSectionScore: Double

        public init(minimumChunkScore: Double = 0.3, foundScore: Double = 0.6, ambiguityGap: Double = 0.12, minimumSectionScore: Double = 0.3) {
            self.minimumChunkScore = minimumChunkScore
            self.foundScore = foundScore
            self.ambiguityGap = ambiguityGap
            self.minimumSectionScore = minimumSectionScore
        }

        public static let `default` = Thresholds()
    }

    public static func evaluate(
        query: String,
        snapshotId: SnapshotID,
        chunks: [SourceChunk],
        sections: [DocumentSection],
        maximumChunks: Int = 16,
        thresholds: Thresholds = .default
    ) -> ScopeResolution {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = normalize(trimmed)
        guard !normalizedQuery.isEmpty else {
            return ScopeResolution(query: trimmed, snapshotId: snapshotId, state: .notFound, message: ScopeResolution.notFoundMessage)
        }

        if isWholeDocumentPhrase(normalizedQuery) {
            return ScopeResolution(
                query: trimmed,
                snapshotId: snapshotId,
                state: .fullDocument,
                suggestedChunkIds: chunks.map(\.id),
                sectionTitles: uniqueSectionTitles(chunks: chunks, sections: sections)
            )
        }

        let queryTokens = contentTokens(trimmed)
        let chapterNumber = chapterReference(in: trimmed)
        let sectionById = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })

        let inputs: [Input] = chunks.map { chunk in
            let title = chunk.sectionId.flatMap { sectionById[$0]?.title } ?? chunk.location.sectionTitle ?? ""
            return Input(chunk: chunk, sectionTitle: title)
        }

        var scored: [(input: Input, score: Double)] = []
        for input in inputs {
            var score = rawScore(query: trimmed, normalizedQuery: normalizedQuery, tokens: queryTokens, input: input)
            if let chapterNumber, matchesChapter(chapterNumber, sectionTitle: input.sectionTitle) {
                score = max(score, 0.85)
            }
            if score >= thresholds.minimumChunkScore {
                scored.append((input, score))
            }
        }

        guard let top = scored.map(\.score).max(), !scored.isEmpty else {
            return ScopeResolution(
                query: trimmed,
                snapshotId: snapshotId,
                state: .notFound,
                message: ScopeResolution.notFoundMessage
            )
        }

        // Score sections by their best chunk.
        var sectionScores: [String: Double] = [:]
        for item in scored {
            let key = item.input.sectionTitle
            sectionScores[key] = max(sectionScores[key] ?? 0, item.score)
        }
        let rankedSections = sectionScores.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        let bestSections = rankedSections.filter { $0.value >= max(thresholds.minimumSectionScore, top - 0.15) }
        let bestTitle = rankedSections.first?.key ?? trimmed

        // Ambiguity: several distinct sections score close to the best one.
        let closeSections = rankedSections.filter { $0.value >= top - thresholds.ambiguityGap }
        let isAmbiguous = closeSections.count > 1 || top < thresholds.foundScore
        let state: ScopeResolutionState = isAmbiguous ? .ambiguous : .found

        let bestSectionNames = Set(bestSections.map(\.key))
        var selected: [(Input, Double)] = scored.filter { bestSectionNames.contains($0.input.sectionTitle) }
        // Include every usable chunk from the matched sections for usable context,
        // even when an individual chunk scored below the threshold.
        for input in inputs where bestSectionNames.contains(input.sectionTitle) {
            if !selected.contains(where: { $0.0.chunk.id == input.chunk.id }) {
                selected.append((input, thresholds.minimumChunkScore))
            }
        }
        selected.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.chunk.order < rhs.0.chunk.order
        }
        var limited = Array(selected.prefix(max(1, maximumChunks)))
        limited.sort { $0.0.chunk.order < $1.0.chunk.order }

        let matches = limited.map { item in
            ScopeMatch(
                chunkId: item.0.chunk.id,
                score: item.1,
                sectionTitle: item.0.sectionTitle.isEmpty ? "Document" : item.0.sectionTitle,
                location: item.0.chunk.location,
                excerpt: String(item.0.chunk.text.prefix(240))
            )
        }
        var seenTitles: Set<String> = []
        let sectionTitles = matches.map(\.sectionTitle).filter { seenTitles.insert($0).inserted }

        return ScopeResolution(
            query: trimmed,
            snapshotId: snapshotId,
            state: state,
            matches: matches,
            suggestedChunkIds: limited.map { $0.0.chunk.id },
            sectionTitles: sectionTitles,
            message: state == .ambiguous
                ? "Several parts of the document match “\(trimmed)”. Confirm the passages you want."
                : nil
        )
    }

    // MARK: Scoring

    static func rawScore(query: String, normalizedQuery: String, tokens: [String], input: Input) -> Double {
        let text = normalize(input.chunk.text)
        let title = normalize(input.sectionTitle)
        let textTokens = Set(contentTokens(input.chunk.text))
        let titleTokens = Set(contentTokens(input.sectionTitle))

        var score = 0.0
        if !tokens.isEmpty {
            let matchedText = tokens.filter { token in
                textTokens.contains(token) || text.contains(token)
            }
            let matchedTitle = tokens.filter { token in
                titleTokens.contains(token) || title.contains(token)
            }
            score += 0.7 * (Double(matchedText.count) / Double(tokens.count))
            score += 0.3 * (Double(matchedTitle.count) / Double(tokens.count))
        }

        if normalizedQuery.count >= 4, text.contains(normalizedQuery) {
            score += 0.35
        }
        if normalizedQuery.count >= 4, title.contains(normalizedQuery) {
            score += 0.15
        }
        return min(1.0, score)
    }

    static func contentTokens(_ text: String) -> [String] {
        var tokens = TextUtilities.contentTokens(text)
        // Keep short numbers so "chapter 3" style requests can match.
        let numbers = text.split(whereSeparator: { !$0.isNumber }).map(String.init).filter { $0.count <= 3 }
        tokens.append(contentsOf: numbers)
        return tokens
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    static func isWholeDocumentPhrase(_ normalized: String) -> Bool {
        let phrases = [
            "entire document", "whole document", "the whole document", "everything", "all of it",
            "tutto il documento", "documento intero", "tout le document", "ganze dokument",
        ]
        return phrases.contains { normalized == $0 || normalized.contains($0) }
    }

    /// "chapter 3", "capitolo 3", "section 2.1", "part IV".
    static func chapterReference(in query: String) -> String? {
        let patterns = [
            #"(?i)\b(chapter|capitolo|section|sezione|part|parte|unit|unità)\s+([0-9]{1,3}|[ivxlc]{1,6})\b"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
               match.numberOfRanges >= 3,
               let range = Range(match.range(at: 2), in: query) {
                return String(query[range]).lowercased()
            }
        }
        return nil
    }

    static func matchesChapter(_ number: String, sectionTitle: String) -> Bool {
        let title = normalize(sectionTitle)
        guard !title.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: number)
        let patterns = [
            "^\\s*\(escaped)\\b",
            "\\b(chapter|capitolo|section|sezione|part|parte|unit|unità)\\s+\(escaped)\\b",
            "^\\s*\(escaped)[.:]",
        ]
        for pattern in patterns {
            if title.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    static func uniqueSectionTitles(chunks: [SourceChunk], sections: [DocumentSection]) -> [String] {
        let sectionById = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        var seen: Set<String> = []
        return chunks.compactMap { chunk in
            let title = chunk.sectionId.flatMap { sectionById[$0]?.title } ?? chunk.location.sectionTitle
            guard let title, seen.insert(title).inserted else { return nil }
            return title
        }
    }
}
