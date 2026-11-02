import Foundation
import GRDB
import StudyDomain

/// GRDB-backed implementation of the single authoritative store.
public final class GRDBStudyRepository: StudyRepository {
    private let database: StudyDatabase

    public init(database: StudyDatabase) {
        self.database = database
    }

    public var supportsFullTextSearch: Bool { database.supportsFullTextSearch }

    // MARK: Documents

    public func saveDocument(_ document: StudyDocument) async throws {
        try await database.queue.write { db in
            try DocumentRecord(document).save(db)
        }
    }

    public func updateDocument(_ document: StudyDocument) async throws {
        try await saveDocument(document)
    }

    public func document(id: DocumentID) async throws -> StudyDocument? {
        try await database.queue.read { db in
            try DocumentRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    public func documents() async throws -> [StudyDocument] {
        try await database.queue.read { db in
            try DocumentRecord
                .order(Column("importedAt").desc)
                .fetchAll(db)
                .map { try $0.domain() }
        }
    }

    public func documentSummaries() async throws -> [DocumentSummary] {
        try await database.queue.read { db in
            let sql = """
                SELECT d.id, d.name, d.fileType, d.storedFileName, d.sha256, d.importedAt, d.state,
                       d.language, d.parserVersion, d.activeSnapshotId,
                       s.qualityJSON,
                       (SELECT COUNT(*) FROM sections se WHERE se.snapshotId = d.activeSnapshotId) AS sectionCount,
                       (SELECT COUNT(*) FROM topics t WHERE t.snapshotId = d.activeSnapshotId) AS topicCount,
                       (SELECT COUNT(*) FROM sessions ss WHERE ss.documentId = d.id) AS sessionCount,
                       (SELECT MAX(ss.startedAt) FROM sessions ss WHERE ss.documentId = d.id) AS lastStudiedAt
                FROM documents d
                LEFT JOIN snapshots s ON s.id = d.activeSnapshotId
                ORDER BY d.importedAt DESC
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                let record = try DocumentRecord(row: row)
                let quality: DocumentQuality? = (row["qualityJSON"] as String?).map {
                    Codec.decode(DocumentQuality.self, from: $0, fallback: DocumentQuality())
                }
                return DocumentSummary(
                    document: try record.domain(),
                    quality: quality,
                    sectionCount: row["sectionCount"],
                    topicCount: row["topicCount"],
                    sessionCount: row["sessionCount"],
                    lastStudiedAt: row["lastStudiedAt"]
                )
            }
        }
    }

    public func saveImport(_ result: DocumentImportResult, document: StudyDocument) async throws {
        try await database.queue.write { db in
            var storedDocument = document
            storedDocument.activeSnapshotId = result.snapshot.id
            try DocumentRecord(storedDocument).save(db)
            try SnapshotRecord(result.snapshot).save(db)
            for section in result.sections { try SectionRecord(section).save(db) }
            for chunk in result.chunks {
                try ChunkRecord(chunk).save(db)
                if database.supportsFullTextSearch {
                    try db.execute(
                        sql: "INSERT INTO chunkSearch (chunkId, snapshotId, text) VALUES (?, ?, ?)",
                        arguments: [chunk.id.rawValue, chunk.snapshotId.rawValue, chunk.text]
                    )
                }
            }
        }
    }

    public func deleteDocument(id: DocumentID) async throws {
        try await database.queue.write { db in
            if database.supportsFullTextSearch {
                try db.execute(
                    sql: """
                        DELETE FROM chunkSearch WHERE snapshotId IN
                        (SELECT id FROM snapshots WHERE documentId = ?)
                        """,
                    arguments: [id.rawValue]
                )
            }
            try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [id.rawValue])
        }
    }

    public func setActiveSnapshot(_ snapshotId: SnapshotID, for documentId: DocumentID) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE documents SET activeSnapshotId = ? WHERE id = ?",
                arguments: [snapshotId.rawValue, documentId.rawValue]
            )
        }
    }

    // MARK: Snapshots, sections, chunks

    public func snapshot(id: SnapshotID) async throws -> DocumentSnapshot? {
        try await database.queue.read { db in
            try SnapshotRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    public func activeSnapshot(for documentId: DocumentID) async throws -> DocumentSnapshot? {
        try await database.queue.read { db in
            guard let document = try DocumentRecord.fetchOne(db, key: documentId.rawValue),
                  let snapshotId = document.activeSnapshotId else { return nil }
            return try SnapshotRecord.fetchOne(db, key: snapshotId)?.domain()
        }
    }

    public func snapshots(documentId: DocumentID) async throws -> [DocumentSnapshot] {
        try await database.queue.read { db in
            try SnapshotRecord
                .filter(sql: "documentId = ?", arguments: [documentId.rawValue])
                .order(Column("version").asc)
                .fetchAll(db)
                .map { $0.domain() }
        }
    }

    public func sections(snapshotId: SnapshotID) async throws -> [DocumentSection] {
        try await database.queue.read { db in
            try SectionRecord
                .filter(sql: "snapshotId = ?", arguments: [snapshotId.rawValue])
                .order(Column("order").asc)
                .fetchAll(db)
                .map { $0.domain() }
        }
    }

    public func section(id: SectionID) async throws -> DocumentSection? {
        try await database.queue.read { db in
            try SectionRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    public func chunks(snapshotId: SnapshotID) async throws -> [SourceChunk] {
        try await database.queue.read { db in
            try ChunkRecord
                .filter(sql: "snapshotId = ?", arguments: [snapshotId.rawValue])
                .order(Column("order").asc)
                .fetchAll(db)
                .map { $0.domain() }
        }
    }

    public func chunks(ids: [ChunkID]) async throws -> [SourceChunk] {
        guard !ids.isEmpty else { return [] }
        let keys = ids.map(\.rawValue)
        return try await database.queue.read { db in
            try ChunkRecord.fetchAll(db, keys: keys).map { $0.domain() }
        }
    }

    public func isFullTextSearchSupported() async -> Bool {
        database.supportsFullTextSearch
    }

    /// Chunk ids matching a full-text query, restricted to one snapshot.
    public func searchChunkIds(query: String, snapshotId: SnapshotID, limit: Int) async throws -> [ChunkID] {
        try await searchRawChunkIds(query: query, snapshotId: snapshotId, limit: limit).map(ChunkID.init(rawValue:))
    }

    private func searchRawChunkIds(query: String, snapshotId: SnapshotID, limit: Int) async throws -> [String] {
        guard database.supportsFullTextSearch else { return [] }
        let tokens = TextUtilities.contentTokens(query)
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " OR ")
        return try await database.queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT chunkId FROM chunkSearch
                    WHERE chunkSearch MATCH ? AND snapshotId = ?
                    LIMIT ?
                    """,
                arguments: [match, snapshotId.rawValue, limit]
            )
        }
    }

    // MARK: Scopes

    public func saveScope(_ scope: StudyScope) async throws {
        try await database.queue.write { db in
            try ScopeRecord(scope).save(db)
        }
    }

    public func scope(id: ScopeID) async throws -> StudyScope? {
        try await database.queue.read { db in
            try ScopeRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    public func scopes(snapshotId: SnapshotID) async throws -> [StudyScope] {
        try await database.queue.read { db in
            try ScopeRecord
                .filter(sql: "snapshotId = ?", arguments: [snapshotId.rawValue])
                .order(Column("createdAt").asc)
                .fetchAll(db)
                .map { $0.domain() }
        }
    }

    // MARK: Topics

    public func saveTopics(_ topics: [Topic]) async throws {
        try await database.queue.write { db in
            for topic in topics { try TopicRecord(topic).save(db) }
        }
    }

    public func topics(snapshotId: SnapshotID) async throws -> [Topic] {
        try await database.queue.read { db in
            try TopicRecord
                .filter(sql: "snapshotId = ?", arguments: [snapshotId.rawValue])
                .order(Column("order").asc)
                .fetchAll(db)
                .map { $0.domain() }
        }
    }

    public func topic(id: TopicID) async throws -> Topic? {
        try await database.queue.read { db in
            try TopicRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    // MARK: Sessions

    public func saveSession(_ session: StudySession) async throws {
        try await database.queue.write { db in
            try SessionRecord(session).save(db)
        }
    }

    public func updateSession(_ session: StudySession) async throws {
        try await saveSession(session)
    }

    public func session(id: SessionID) async throws -> StudySession? {
        try await database.queue.read { db in
            try SessionRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    public func sessions(documentId: DocumentID?) async throws -> [StudySession] {
        try await database.queue.read { db in
            var request = SessionRecord.order(Column("startedAt").desc)
            if let documentId {
                request = request.filter(sql: "documentId = ?", arguments: [documentId.rawValue])
            }
            return try request.fetchAll(db).map { $0.domain() }
        }
    }

    public func activeSession(for documentId: DocumentID) async throws -> StudySession? {
        try await database.queue.read { db in
            try SessionRecord
                .filter(sql: "documentId = ? AND state = ?", arguments: [documentId.rawValue, SessionState.active.rawValue])
                .order(Column("startedAt").desc)
                .fetchOne(db)?
                .domain()
        }
    }

    public func sessionProgress(sessionId: SessionID) async throws -> SessionProgress? {
        try await database.queue.read { db in
            guard let session = try SessionRecord.fetchOne(db, key: sessionId.rawValue)?.domain() else { return nil }
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.status AS status, e.userOverrideJSON AS overrideJSON
                FROM attempts a
                JOIN questions q ON q.id = a.questionId
                JOIN evaluations e ON e.attemptId = a.id
                WHERE q.sessionId = ?
                """, arguments: [sessionId.rawValue])
            var counts: [EvaluationStatus: Int] = [:]
            for row in rows {
                let status = Self.effectiveStatus(row: row)
                counts[status, default: 0] += 1
            }
            let answered = counts.values.reduce(0, +)
            return SessionProgress(session: session, answeredCount: answered, statusCounts: counts)
        }
    }

    // MARK: Questions, attempts, evaluations

    public func saveDraft(questionId: QuestionID, text: String) async throws {
        try await database.queue.write { db in
            try DraftRecord(questionId: questionId.rawValue, text: text, updatedAt: Date()).save(db)
        }
    }

    public func draftText(questionId: QuestionID) async throws -> String? {
        try await database.queue.read { db in
            try DraftRecord.fetchOne(db, key: questionId.rawValue)?.text
        }
    }

    public func deleteDraft(questionId: QuestionID) async throws {
        try await database.queue.write { db in
            try db.execute(sql: "DELETE FROM drafts WHERE questionId = ?", arguments: [questionId.rawValue])
        }
    }

    public func saveQuestion(_ question: Question) async throws {
        try await database.queue.write { db in
            try QuestionRecord(question).save(db)
        }
    }

    public func question(id: QuestionID) async throws -> Question? {
        try await database.queue.read { db in
            try QuestionRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    public func questions(sessionId: SessionID) async throws -> [Question] {
        try await database.queue.read { db in
            try QuestionRecord
                .filter(sql: "sessionId = ?", arguments: [sessionId.rawValue])
                .order(Column("createdAt").asc)
                .fetchAll(db)
                .map { try $0.domain() }
        }
    }

    public func questionHashes(snapshotId: SnapshotID) async throws -> Set<String> {
        try await database.queue.read { db in
            let hashes = try String.fetchAll(db, sql: """
                SELECT q.normalizedTextHash FROM questions q
                JOIN sessions s ON s.id = q.sessionId
                WHERE s.snapshotId = ?
                """, arguments: [snapshotId.rawValue])
            return Set(hashes)
        }
    }

    public func saveAttempt(_ attempt: AnswerAttempt) async throws {
        try await database.queue.write { db in
            try AttemptRecord(attempt).save(db)
        }
    }

    public func updateAttempt(_ attempt: AnswerAttempt) async throws {
        try await saveAttempt(attempt)
    }

    public func attempts(questionId: QuestionID) async throws -> [AnswerAttempt] {
        try await database.queue.read { db in
            try AttemptRecord
                .filter(sql: "questionId = ?", arguments: [questionId.rawValue])
                .order(Column("createdAt").asc)
                .fetchAll(db)
                .map { $0.domain() }
        }
    }

    public func latestAttempt(questionId: QuestionID) async throws -> AnswerAttempt? {
        try await database.queue.read { db in
            try AttemptRecord
                .filter(sql: "questionId = ?", arguments: [questionId.rawValue])
                .order(Column("createdAt").desc)
                .fetchOne(db)?
                .domain()
        }
    }

    public func saveEvaluation(_ evaluation: Evaluation) async throws {
        try await database.queue.write { db in
            try EvaluationRecord(evaluation).save(db)
        }
    }

    public func updateEvaluation(_ evaluation: Evaluation) async throws {
        try await saveEvaluation(evaluation)
    }

    public func deleteAttempt(id: AttemptID) async throws {
        try await database.queue.write { db in
            try db.execute(sql: "DELETE FROM attempts WHERE id = ?", arguments: [id.rawValue])
        }
    }

    public func evaluation(id: EvaluationID) async throws -> Evaluation? {
        try await database.queue.read { db in
            try EvaluationRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    public func evaluation(forAttempt attemptId: AttemptID) async throws -> Evaluation? {
        try await database.queue.read { db in
            try EvaluationRecord
                .filter(sql: "attemptId = ?", arguments: [attemptId.rawValue])
                .order(Column("createdAt").desc)
                .fetchOne(db)?
                .domain()
        }
    }

    // MARK: Progress and history

    public func topicAttempts(snapshotId: SnapshotID) async throws -> [TopicAttempt] {
        try await database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT q.topicId AS topicId, q.id AS questionId, s.id AS sessionId,
                       a.createdAt AS createdAt, e.status AS status, e.userOverrideJSON AS overrideJSON
                FROM attempts a
                JOIN questions q ON q.id = a.questionId
                JOIN sessions s ON s.id = q.sessionId
                JOIN evaluations e ON e.attemptId = a.id
                WHERE s.snapshotId = ?
                ORDER BY a.createdAt ASC
                """, arguments: [snapshotId.rawValue])
            return rows.map { row in
                TopicAttempt(
                    topicId: TopicID(rawValue: row["topicId"]),
                    questionId: QuestionID(rawValue: row["questionId"]),
                    sessionId: SessionID(rawValue: row["sessionId"]),
                    status: Self.effectiveStatus(row: row),
                    createdAt: row["createdAt"]
                )
            }
        }
    }

    public func sessionHistory(sessionId: SessionID) async throws -> [HistoryRecord] {
        try await history(filters: HistoryFilters(), restrictedToSession: sessionId)
    }

    public func history(filters: HistoryFilters) async throws -> [HistoryRecord] {
        try await history(filters: filters, restrictedToSession: nil)
    }

    private func history(filters: HistoryFilters, restrictedToSession: SessionID?) async throws -> [HistoryRecord] {
        try await database.queue.read { db in
            var conditions: [String] = []
            var arguments: StatementArguments = []
            if let sessionId = restrictedToSession {
                conditions.append("q.sessionId = ?")
                arguments += [sessionId.rawValue]
            }
            if let documentId = filters.documentId {
                conditions.append("s.documentId = ?")
                arguments += [documentId.rawValue]
            }
            if let from = filters.from {
                conditions.append("a.createdAt >= ?")
                arguments += [from]
            }
            if let to = filters.to {
                conditions.append("a.createdAt <= ?")
                arguments += [to]
            }
            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT a.id AS id
                FROM attempts a
                JOIN questions q ON q.id = a.questionId
                JOIN sessions s ON s.id = q.sessionId
                \(whereClause)
                ORDER BY a.createdAt DESC
                LIMIT 2000
                """
            let attemptIds = try String.fetchAll(db, sql: sql, arguments: arguments)

            var records: [HistoryRecord] = []
            for attemptId in attemptIds {
                guard let attempt = try AttemptRecord.fetchOne(db, key: attemptId)?.domain(),
                      let question = try QuestionRecord.fetchOne(db, key: attempt.questionId.rawValue)?.domain(),
                      let session = try SessionRecord.fetchOne(db, key: question.sessionId.rawValue)?.domain(),
                      let document = try DocumentRecord.fetchOne(db, key: session.documentId.rawValue)?.domain()
                else { continue }
                let evaluation = try EvaluationRecord
                    .filter(sql: "attemptId = ?", arguments: [attemptId])
                    .order(Column("createdAt").desc)
                    .fetchOne(db)?
                    .domain()
                if let requested = filters.status, evaluation?.effectiveStatus != requested { continue }
                let topicTitle = try TopicRecord.fetchOne(db, key: question.topicId.rawValue)?.title
                let scope = try question.scopeId.flatMap { try ScopeRecord.fetchOne(db, key: $0.rawValue)?.domain() }
                records.append(
                    HistoryRecord(
                        session: session,
                        documentName: document.name,
                        topicTitle: topicTitle,
                        question: question,
                        attempt: attempt,
                        evaluation: evaluation,
                        scope: scope
                    )
                )
            }
            return records
        }
    }

    static func effectiveStatus(row: Row) -> EvaluationStatus {
        let raw: String = row["status"]
        let base = EvaluationStatus(rawValue: raw) ?? .notEvaluable
        if let overrideJSON: String = row["overrideJSON"],
           let override = try? Codec.decoder.decode(EvaluationOverride.self, from: Data(overrideJSON.utf8)) {
            return override.status
        }
        return base
    }

    // MARK: Prompts

    public func savePromptVersion(_ version: PromptVersion) async throws {
        try await database.queue.write { db in
            if version.isDefault {
                try db.execute(sql: "UPDATE promptVersions SET isDefault = 0")
            }
            try PromptVersionRecord(version).save(db)
        }
    }

    public func promptVersions() async throws -> [PromptVersion] {
        try await database.queue.read { db in
            try PromptVersionRecord
                .order(Column("editedAt").desc)
                .fetchAll(db)
                .map { $0.domain() }
        }
    }

    public func promptVersion(id: PromptVersionID) async throws -> PromptVersion? {
        try await database.queue.read { db in
            try PromptVersionRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    public func activePromptVersion() async throws -> PromptVersion? {
        try await database.queue.read { db in
            if let id = try SettingRecord.fetchOne(db, key: SettingKey.activePromptVersionId)?.value,
               let version = try PromptVersionRecord.fetchOne(db, key: id)?.domain() {
                return version
            }
            return try PromptVersionRecord
                .order(Column("editedAt").desc)
                .fetchOne(db)?
                .domain()
        }
    }

    public func setActivePromptVersion(_ id: PromptVersionID) async throws {
        try await database.queue.write { db in
            try SettingRecord(key: SettingKey.activePromptVersionId, value: id.rawValue).save(db)
        }
    }

    // MARK: Provider profiles

    public func saveProviderProfile(_ profile: ProviderProfile) async throws {
        try await database.queue.write { db in
            try ProviderProfileRecord(profile).save(db)
        }
    }

    public func providerProfiles() async throws -> [ProviderProfile] {
        try await database.queue.read { db in
            try ProviderProfileRecord
                .order(Column("createdAt").asc)
                .fetchAll(db)
                .map { $0.domain() }
        }
    }

    public func providerProfile(id: ProviderProfileID) async throws -> ProviderProfile? {
        try await database.queue.read { db in
            try ProviderProfileRecord.fetchOne(db, key: id.rawValue)?.domain()
        }
    }

    public func deleteProviderProfile(id: ProviderProfileID) async throws {
        try await database.queue.write { db in
            try db.execute(sql: "DELETE FROM providerProfiles WHERE id = ?", arguments: [id.rawValue])
            if try SettingRecord.fetchOne(db, key: SettingKey.activeProviderProfileId)?.value == id.rawValue {
                try db.execute(sql: "DELETE FROM appSettings WHERE key = ?", arguments: [SettingKey.activeProviderProfileId])
            }
        }
    }

    public func activeProviderProfile() async throws -> ProviderProfile? {
        try await database.queue.read { db in
            if let id = try SettingRecord.fetchOne(db, key: SettingKey.activeProviderProfileId)?.value,
               let profile = try ProviderProfileRecord.fetchOne(db, key: id)?.domain() {
                return profile
            }
            return nil
        }
    }

    public func setActiveProviderProfile(_ id: ProviderProfileID?) async throws {
        try await database.queue.write { db in
            if let id {
                try SettingRecord(key: SettingKey.activeProviderProfileId, value: id.rawValue).save(db)
            } else {
                try db.execute(sql: "DELETE FROM appSettings WHERE key = ?", arguments: [SettingKey.activeProviderProfileId])
            }
        }
    }

    // MARK: Speech profiles

    public func saveSpeechProfile(_ profile: SpeechProfile) async throws {
        try await database.queue.write { db in
            try SpeechProfileRecord(profile).save(db)
        }
    }

    public func speechProfiles() async throws -> [SpeechProfile] {
        try await database.queue.read { db in
            try SpeechProfileRecord
                .order(Column("createdAt").asc)
                .fetchAll(db)
                .map { $0.domain() }
        }
    }

    public func activeSpeechProfile() async throws -> SpeechProfile? {
        try await database.queue.read { db in
            if let id = try SettingRecord.fetchOne(db, key: SettingKey.activeSpeechProfileId)?.value,
               let profile = try SpeechProfileRecord.fetchOne(db, key: id)?.domain() {
                return profile
            }
            return nil
        }
    }

    public func setActiveSpeechProfile(_ id: SpeechProfileID?) async throws {
        try await database.queue.write { db in
            if let id {
                try SettingRecord(key: SettingKey.activeSpeechProfileId, value: id.rawValue).save(db)
            } else {
                try db.execute(sql: "DELETE FROM appSettings WHERE key = ?", arguments: [SettingKey.activeSpeechProfileId])
            }
        }
    }

    public func deleteSpeechProfile(id: SpeechProfileID) async throws {
        try await database.queue.write { db in
            try db.execute(sql: "DELETE FROM speechProfiles WHERE id = ?", arguments: [id.rawValue])
            if try SettingRecord.fetchOne(db, key: SettingKey.activeSpeechProfileId)?.value == id.rawValue {
                try db.execute(sql: "DELETE FROM appSettings WHERE key = ?", arguments: [SettingKey.activeSpeechProfileId])
            }
        }
    }

    // MARK: Danger zone

    public func deleteAllStudyData() async throws {
        try await database.queue.write { db in
            if database.supportsFullTextSearch {
                try db.execute(sql: "DELETE FROM chunkSearch")
            }
            for table in ["drafts", "evaluations", "attempts", "questions", "sessions", "scopes", "topics", "chunks", "sections", "snapshots", "documents"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    // MARK: Settings helpers

    public func setting(key: String) async throws -> String? {
        try await database.queue.read { db in
            try SettingRecord.fetchOne(db, key: key)?.value
        }
    }

    public func setSetting(key: String, value: String?) async throws {
        try await database.queue.write { db in
            if let value {
                try SettingRecord(key: key, value: value).save(db)
            } else {
                try db.execute(sql: "DELETE FROM appSettings WHERE key = ?", arguments: [key])
            }
        }
    }
}
