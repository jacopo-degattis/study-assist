import Foundation
import GRDB
import StudyDomain

/// row → domain conversions. All JSON columns are encoded here.
enum Codec {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String?, fallback: T) -> T {
        guard let string, let data = string.data(using: .utf8) else { return fallback }
        return (try? decoder.decode(type, from: data)) ?? fallback
    }
}

// MARK: - Documents

struct DocumentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "documents"
    var id: String
    var name: String
    var fileType: String
    var storedFileName: String
    var sha256: String
    var importedAt: Date
    var state: String
    var language: String?
    var parserVersion: String
    var activeSnapshotId: String?

    init(_ document: StudyDocument) {
        id = document.id.rawValue
        name = document.name
        fileType = document.fileType.rawValue
        storedFileName = document.storedFileName
        sha256 = document.sha256
        importedAt = document.importedAt
        state = document.state.rawValue
        language = document.language
        parserVersion = document.parserVersion
        activeSnapshotId = document.activeSnapshotId?.rawValue
    }

    func domain() throws -> StudyDocument {
        guard let fileType = DocumentFileType(rawValue: fileType) else {
            throw AppError.persistenceFailure("Unknown file type \(fileType) in document \(id).")
        }
        guard let state = DocumentState(rawValue: state) else {
            throw AppError.persistenceFailure("Unknown document state in document \(id).")
        }
        return StudyDocument(
            id: DocumentID(rawValue: id),
            name: name,
            fileType: fileType,
            storedFileName: storedFileName,
            sha256: sha256,
            importedAt: importedAt,
            state: state,
            language: language,
            parserVersion: parserVersion,
            activeSnapshotId: activeSnapshotId.map(SnapshotID.init(rawValue:))
        )
    }
}

struct SnapshotRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "snapshots"
    var id: String
    var documentId: String
    var version: Int
    var textHash: String
    var qualityJSON: String
    var createdAt: Date

    init(_ snapshot: DocumentSnapshot) {
        id = snapshot.id.rawValue
        documentId = snapshot.documentId.rawValue
        version = snapshot.version
        textHash = snapshot.textHash
        qualityJSON = Codec.encode(snapshot.quality)
        createdAt = snapshot.createdAt
    }

    func domain() -> DocumentSnapshot {
        DocumentSnapshot(
            id: SnapshotID(rawValue: id),
            documentId: DocumentID(rawValue: documentId),
            version: version,
            textHash: textHash,
            quality: Codec.decode(DocumentQuality.self, from: qualityJSON, fallback: DocumentQuality()),
            createdAt: createdAt
        )
    }
}

struct SectionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sections"
    var id: String
    var snapshotId: String
    var title: String
    var level: Int
    var order: Int
    var locationJSON: String

    init(_ section: DocumentSection) {
        id = section.id.rawValue
        snapshotId = section.snapshotId.rawValue
        title = section.title
        level = section.level
        order = section.order
        locationJSON = Codec.encode(section.location)
    }

    func domain() -> DocumentSection {
        DocumentSection(
            id: SectionID(rawValue: id),
            snapshotId: SnapshotID(rawValue: snapshotId),
            title: title,
            level: level,
            order: order,
            location: Codec.decode(SourceLocation.self, from: locationJSON, fallback: SourceLocation())
        )
    }
}

struct ChunkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chunks"
    var id: String
    var snapshotId: String
    var text: String
    var sectionId: String?
    var locationJSON: String
    var startOffset: Int
    var endOffset: Int
    var extractionMethod: String
    var quality: Double
    var isUsableAsEvidence: Bool
    var order: Int

    init(_ chunk: SourceChunk) {
        id = chunk.id.rawValue
        snapshotId = chunk.snapshotId.rawValue
        text = chunk.text
        sectionId = chunk.sectionId?.rawValue
        locationJSON = Codec.encode(chunk.location)
        startOffset = chunk.startOffset
        endOffset = chunk.endOffset
        extractionMethod = chunk.extractionMethod.rawValue
        quality = chunk.quality
        isUsableAsEvidence = chunk.isUsableAsEvidence
        order = chunk.order
    }

    func domain() -> SourceChunk {
        SourceChunk(
            id: ChunkID(rawValue: id),
            snapshotId: SnapshotID(rawValue: snapshotId),
            text: text,
            sectionId: sectionId.map(SectionID.init(rawValue:)),
            location: Codec.decode(SourceLocation.self, from: locationJSON, fallback: SourceLocation()),
            startOffset: startOffset,
            endOffset: endOffset,
            extractionMethod: ExtractionMethod(rawValue: extractionMethod) ?? .pdfText,
            quality: quality,
            isUsableAsEvidence: isUsableAsEvidence,
            order: order
        )
    }
}

struct ScopeRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "scopes"
    var id: String
    var snapshotId: String
    var query: String
    var title: String
    var matchedChunkIdsJSON: String
    var isFullDocument: Bool
    var version: Int
    var confirmedByUser: Bool
    var createdAt: Date

    init(_ scope: StudyScope) {
        id = scope.id.rawValue
        snapshotId = scope.snapshotId.rawValue
        query = scope.query
        title = scope.title
        matchedChunkIdsJSON = Codec.encode(scope.matchedChunkIds.map(\.rawValue))
        isFullDocument = scope.isFullDocument
        version = scope.version
        confirmedByUser = scope.confirmedByUser
        createdAt = scope.createdAt
    }

    func domain() -> StudyScope {
        let ids = Codec.decode([String].self, from: matchedChunkIdsJSON, fallback: [])
        return StudyScope(
            id: ScopeID(rawValue: id),
            snapshotId: SnapshotID(rawValue: snapshotId),
            query: query,
            title: title,
            matchedChunkIds: ids.map(ChunkID.init(rawValue:)),
            isFullDocument: isFullDocument,
            version: version,
            confirmedByUser: confirmedByUser,
            createdAt: createdAt
        )
    }
}

struct TopicRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "topics"
    var id: String
    var snapshotId: String
    var title: String
    var chunkIdsJSON: String
    var order: Int

    init(_ topic: Topic) {
        id = topic.id.rawValue
        snapshotId = topic.snapshotId.rawValue
        title = topic.title
        chunkIdsJSON = Codec.encode(topic.sourceChunkIds.map(\.rawValue))
        order = topic.order
    }

    func domain() -> Topic {
        let ids = Codec.decode([String].self, from: chunkIdsJSON, fallback: [])
        return Topic(
            id: TopicID(rawValue: id),
            snapshotId: SnapshotID(rawValue: snapshotId),
            title: title,
            sourceChunkIds: ids.map(ChunkID.init(rawValue:)),
            order: order
        )
    }
}

struct SessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessions"
    var id: String
    var documentId: String
    var snapshotId: String
    var startedAt: Date
    var finishedAt: Date?
    var mode: String
    var promptVersionId: String
    var modelProfileId: String?
    var state: String
    var scopeId: String?
    var currentScopeId: String?

    init(_ session: StudySession) {
        id = session.id.rawValue
        documentId = session.documentId.rawValue
        snapshotId = session.snapshotId.rawValue
        startedAt = session.startedAt
        finishedAt = session.finishedAt
        mode = session.mode.rawValue
        promptVersionId = session.promptVersionId.rawValue
        modelProfileId = session.modelProfileId?.rawValue
        state = session.state.rawValue
        scopeId = session.scopeId?.rawValue
        currentScopeId = session.currentScopeId?.rawValue
    }

    func domain() -> StudySession {
        StudySession(
            id: SessionID(rawValue: id),
            documentId: DocumentID(rawValue: documentId),
            snapshotId: SnapshotID(rawValue: snapshotId),
            startedAt: startedAt,
            finishedAt: finishedAt,
            mode: SessionMode(rawValue: mode) ?? .fullStudy,
            promptVersionId: PromptVersionID(rawValue: promptVersionId),
            modelProfileId: modelProfileId.map(ProviderProfileID.init(rawValue:)),
            state: SessionState(rawValue: state) ?? .active,
            scopeId: scopeId.map(ScopeID.init(rawValue:)),
            currentScopeId: currentScopeId.map(ScopeID.init(rawValue:))
        )
    }
}

struct QuestionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "questions"
    var id: String
    var sessionId: String
    var topicId: String
    var text: String
    var rubricJSON: String
    var createdAt: Date
    var normalizedTextHash: String
    var scopeId: String?

    init(_ question: Question) {
        id = question.id.rawValue
        sessionId = question.sessionId.rawValue
        topicId = question.topicId.rawValue
        text = question.text
        rubricJSON = Codec.encode(question.rubric)
        createdAt = question.createdAt
        normalizedTextHash = question.normalizedTextHash
        scopeId = question.scopeId?.rawValue
    }

    func domain() throws -> Question {
        let rubric = try Codec.decoder.decode(QuestionRubric.self, from: Data(rubricJSON.utf8))
        return Question(
            id: QuestionID(rawValue: id),
            sessionId: SessionID(rawValue: sessionId),
            topicId: TopicID(rawValue: topicId),
            text: text,
            rubric: rubric,
            createdAt: createdAt,
            normalizedTextHash: normalizedTextHash,
            scopeId: scopeId.map(ScopeID.init(rawValue:))
        )
    }
}

struct AttemptRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "attempts"
    var id: String
    var questionId: String
    var text: String
    var inputMode: String
    var rawTranscript: String?
    var createdAt: Date
    var evaluationId: String?

    init(_ attempt: AnswerAttempt) {
        id = attempt.id.rawValue
        questionId = attempt.questionId.rawValue
        text = attempt.text
        inputMode = attempt.inputMode.rawValue
        rawTranscript = attempt.rawTranscript
        createdAt = attempt.createdAt
        evaluationId = attempt.evaluationId?.rawValue
    }

    func domain() -> AnswerAttempt {
        AnswerAttempt(
            id: AttemptID(rawValue: id),
            questionId: QuestionID(rawValue: questionId),
            text: text,
            inputMode: AnswerInputMode(rawValue: inputMode) ?? .typed,
            rawTranscript: rawTranscript,
            createdAt: createdAt,
            evaluationId: evaluationId.map(EvaluationID.init(rawValue:))
        )
    }
}

struct DraftRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "drafts"
    static let primaryKey = ["questionId"]
    var questionId: String
    var text: String
    var updatedAt: Date
}

struct EvaluationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "evaluations"
    var id: String
    var attemptId: String
    var status: String
    var feedback: String
    var correctPointIdsJSON: String
    var missingPointIdsJSON: String
    var incorrectStatementsJSON: String
    var evidenceChunkIdsJSON: String
    var providerProfileId: String?
    var modelId: String?
    var promptVersionId: String?
    var createdAt: Date
    var notEvaluableReason: String?
    var userOverrideJSON: String?

    init(_ evaluation: Evaluation) {
        id = evaluation.id.rawValue
        attemptId = evaluation.attemptId.rawValue
        status = evaluation.status.rawValue
        feedback = evaluation.feedback
        correctPointIdsJSON = Codec.encode(evaluation.correctPointIds)
        missingPointIdsJSON = Codec.encode(evaluation.missingPointIds)
        incorrectStatementsJSON = Codec.encode(evaluation.incorrectStatements)
        evidenceChunkIdsJSON = Codec.encode(evaluation.evidenceChunkIds.map(\.rawValue))
        providerProfileId = evaluation.providerProfileId?.rawValue
        modelId = evaluation.modelId
        promptVersionId = evaluation.promptVersionId?.rawValue
        createdAt = evaluation.createdAt
        notEvaluableReason = evaluation.notEvaluableReason
        userOverrideJSON = evaluation.userOverride.map { Codec.encode($0) }
    }

    func domain() -> Evaluation {
        let evidenceIds = Codec.decode([String].self, from: evidenceChunkIdsJSON, fallback: [])
        return Evaluation(
            id: EvaluationID(rawValue: id),
            attemptId: AttemptID(rawValue: attemptId),
            status: EvaluationStatus(rawValue: status) ?? .notEvaluable,
            feedback: feedback,
            correctPointIds: Codec.decode([String].self, from: correctPointIdsJSON, fallback: []),
            missingPointIds: Codec.decode([String].self, from: missingPointIdsJSON, fallback: []),
            incorrectStatements: Codec.decode([String].self, from: incorrectStatementsJSON, fallback: []),
            evidenceChunkIds: evidenceIds.map(ChunkID.init(rawValue:)),
            providerProfileId: providerProfileId.map(ProviderProfileID.init(rawValue:)),
            modelId: modelId,
            promptVersionId: promptVersionId.map(PromptVersionID.init(rawValue:)),
            createdAt: createdAt,
            notEvaluableReason: notEvaluableReason,
            userOverride: Codec.decode(EvaluationOverride?.self, from: userOverrideJSON, fallback: nil)
        )
    }
}

struct PromptVersionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "promptVersions"
    var id: String
    var content: String
    var contentHash: String
    var editedAt: Date
    var isDefault: Bool

    init(_ version: PromptVersion) {
        id = version.id.rawValue
        content = version.content
        contentHash = version.contentHash
        editedAt = version.editedAt
        isDefault = version.isDefault
    }

    func domain() -> PromptVersion {
        PromptVersion(
            id: PromptVersionID(rawValue: id),
            content: content,
            contentHash: contentHash,
            editedAt: editedAt,
            isDefault: isDefault
        )
    }
}

struct ProviderProfileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "providerProfiles"
    var id: String
    var name: String
    var baseURL: String
    var apiStyle: String
    var modelId: String
    var keychainRef: String?
    var requiresAuthentication: Bool
    var extraHeadersJSON: String
    var timeoutSeconds: Double
    var maxRetries: Int
    var createdAt: Date
    var lastConnectionTest: Date?
    var lastConnectionSucceeded: Bool?

    init(_ profile: ProviderProfile) {
        id = profile.id.rawValue
        name = profile.name
        baseURL = profile.baseURL
        apiStyle = profile.apiStyle.rawValue
        modelId = profile.modelId
        keychainRef = profile.keychainRef
        requiresAuthentication = profile.requiresAuthentication
        extraHeadersJSON = Codec.encode(profile.extraHeaders)
        timeoutSeconds = profile.timeoutSeconds
        maxRetries = profile.maxRetries
        createdAt = profile.createdAt
        lastConnectionTest = profile.lastConnectionTest
        lastConnectionSucceeded = profile.lastConnectionSucceeded
    }

    func domain() -> ProviderProfile {
        ProviderProfile(
            id: ProviderProfileID(rawValue: id),
            name: name,
            baseURL: baseURL,
            apiStyle: ProviderAPIStyle(rawValue: apiStyle) ?? .chatCompletions,
            modelId: modelId,
            keychainRef: keychainRef,
            requiresAuthentication: requiresAuthentication,
            extraHeaders: Codec.decode([String: String].self, from: extraHeadersJSON, fallback: [:]),
            timeoutSeconds: timeoutSeconds,
            maxRetries: maxRetries,
            createdAt: createdAt,
            lastConnectionTest: lastConnectionTest,
            lastConnectionSucceeded: lastConnectionSucceeded
        )
    }
}

struct SpeechProfileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "speechProfiles"
    var id: String
    var engine: String
    var modelId: String?
    var isLocal: Bool
    var keychainRef: String?
    var language: String?
    var remoteBaseURL: String?
    var createdAt: Date

    init(_ profile: SpeechProfile) {
        id = profile.id.rawValue
        engine = profile.engine.rawValue
        modelId = profile.modelId
        isLocal = profile.isLocal
        keychainRef = profile.keychainRef
        language = profile.language
        remoteBaseURL = profile.remoteBaseURL
        createdAt = profile.createdAt
    }

    func domain() -> SpeechProfile {
        SpeechProfile(
            id: SpeechProfileID(rawValue: id),
            engine: SpeechEngine(rawValue: engine) ?? .appleOnDevice,
            modelId: modelId,
            isLocal: isLocal,
            keychainRef: keychainRef,
            language: language,
            remoteBaseURL: remoteBaseURL,
            createdAt: createdAt
        )
    }
}

struct SettingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "appSettings"
    static let primaryKey = ["key"]
    var key: String
    var value: String
}
