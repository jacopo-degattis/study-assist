import Foundation

// MARK: - Document import

/// Everything the importer needs about one file, decided by the caller.
public struct DocumentImportRequest: Sendable {
    public var sourceURL: URL
    /// Destination inside app-owned storage. The importer copies the file there.
    public var destinationURL: URL
    public var documentId: DocumentID
    public var documentName: String

    public init(sourceURL: URL, destinationURL: URL, documentId: DocumentID, documentName: String) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.documentId = documentId
        self.documentName = documentName
    }
}

/// Turns a file into provenance-aware snapshot, sections and chunks.
/// Implementations never call an LLM.
public protocol DocumentImporter: Sendable {
    var supportedType: DocumentFileType { get }
    var parserVersion: String { get }

    /// Imports the file described by `request`, copying the original into app
    /// storage. Never blocks the main thread; reports progress incrementally.
    func importDocument(
        _ request: DocumentImportRequest,
        progress: @Sendable (ImportProgress) -> Void
    ) async throws -> DocumentImportResult
}

// MARK: - Retrieval

/// Returns only passages from the active snapshot of one document.
public protocol EvidenceRetriever: Sendable {
    func evidence(for topic: Topic, in snapshotId: SnapshotID) async throws -> [SourceChunk]
    func evidence(forChunkIds ids: [ChunkID], in snapshotId: SnapshotID) async throws -> [SourceChunk]
    func search(_ query: String, in snapshotId: SnapshotID, limit: Int) async throws -> [SourceChunk]
}

// MARK: - LLM

public enum LLMResponseFormat: Sendable, Equatable {
    case text
    case jsonObject
    case jsonSchema(name: String, schemaJSON: String)
}

public struct LLMRequest: Sendable, Equatable {
    public var system: String
    public var user: String
    public var responseFormat: LLMResponseFormat
    public var temperature: Double
    public var maxOutputTokens: Int?
    /// Stable identifier for this conversation. Sent to providers that need it
    /// for routing (OpenCode Go uses `x-opencode-session`) and never to others.
    public var conversationID: String?

    public init(
        system: String,
        user: String,
        responseFormat: LLMResponseFormat = .text,
        temperature: Double = 0.2,
        maxOutputTokens: Int? = nil,
        conversationID: String? = nil
    ) {
        self.system = system
        self.user = user
        self.responseFormat = responseFormat
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.conversationID = conversationID
    }
}

public struct LLMCompletion: Sendable {
    public var text: String
    public var modelId: String
    public var providerProfileId: ProviderProfileID
    public var latency: TimeInterval
    public var responseFormatUsed: LLMResponseFormat

    public init(text: String, modelId: String, providerProfileId: ProviderProfileID, latency: TimeInterval, responseFormatUsed: LLMResponseFormat) {
        self.text = text
        self.modelId = modelId
        self.providerProfileId = providerProfileId
        self.latency = latency
        self.responseFormatUsed = responseFormatUsed
    }
}

public struct ConnectionTestResult: Sendable {
    public var modelId: String
    public var latency: TimeInterval
    public var responseFormatSupported: Bool
    public var detail: String

    public init(modelId: String, latency: TimeInterval, responseFormatSupported: Bool, detail: String) {
        self.modelId = modelId
        self.latency = latency
        self.responseFormatSupported = responseFormatSupported
        self.detail = detail
    }
}

/// Transport, authentication, timeouts and decoding — not pedagogical policy.
public protocol LLMProvider: Sendable {
    var profile: ProviderProfile { get }
    func testConnection() async throws -> ConnectionTestResult
    func complete(_ request: LLMRequest) async throws -> LLMCompletion
}

// MARK: - Speech

public struct TranscriberAvailability: Sendable, Hashable {
    public var isAvailable: Bool
    public var requiresDownload: Bool
    public var approximateDownloadMegabytes: Int?
    public var detail: String

    public init(isAvailable: Bool, requiresDownload: Bool, approximateDownloadMegabytes: Int? = nil, detail: String) {
        self.isAvailable = isAvailable
        self.requiresDownload = requiresDownload
        self.approximateDownloadMegabytes = approximateDownloadMegabytes
        self.detail = detail
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public var text: String
    public var language: String?
    public var engine: SpeechEngine
    public var duration: TimeInterval?

    public init(text: String, language: String? = nil, engine: SpeechEngine, duration: TimeInterval? = nil) {
        self.text = text
        self.language = language
        self.engine = engine
        self.duration = duration
    }
}

/// Converts audio to text. Never grades answers.
public protocol SpeechTranscriber: Sendable {
    var engine: SpeechEngine { get }
    func availability() async -> TranscriberAvailability
    func installIfNeeded(progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(audioAt url: URL) async throws -> TranscriptionResult
    func removeInstalledModels() async throws
}

public extension SpeechTranscriber {
    func installIfNeeded(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func removeInstalledModels() async throws {}
}

// MARK: - Persistence

public struct DocumentSummary: Sendable, Hashable {
    public var document: StudyDocument
    public var quality: DocumentQuality?
    public var sectionCount: Int
    public var topicCount: Int
    public var sessionCount: Int
    public var lastStudiedAt: Date?

    public init(document: StudyDocument, quality: DocumentQuality?, sectionCount: Int, topicCount: Int, sessionCount: Int, lastStudiedAt: Date?) {
        self.document = document
        self.quality = quality
        self.sectionCount = sectionCount
        self.topicCount = topicCount
        self.sessionCount = sessionCount
        self.lastStudiedAt = lastStudiedAt
    }
}

public struct HistoryFilters: Sendable, Hashable {
    public var documentId: DocumentID?
    public var from: Date?
    public var to: Date?
    public var status: EvaluationStatus?

    public init(documentId: DocumentID? = nil, from: Date? = nil, to: Date? = nil, status: EvaluationStatus? = nil) {
        self.documentId = documentId
        self.from = from
        self.to = to
        self.status = status
    }

    public static let all = HistoryFilters()
}

public struct HistoryRecord: Sendable, Hashable, Identifiable {
    public var session: StudySession
    public var documentName: String
    public var topicTitle: String?
    public var question: Question
    public var attempt: AnswerAttempt
    public var evaluation: Evaluation?
    /// The focus this question was asked in, with its query and allowed passages.
    public var scope: StudyScope?

    public var id: String { attempt.id.rawValue }

    public init(session: StudySession, documentName: String, topicTitle: String?, question: Question, attempt: AnswerAttempt, evaluation: Evaluation?, scope: StudyScope? = nil) {
        self.session = session
        self.documentName = documentName
        self.topicTitle = topicTitle
        self.question = question
        self.attempt = attempt
        self.evaluation = evaluation
        self.scope = scope
    }
}

public struct SessionProgress: Sendable, Hashable {
    public var session: StudySession
    public var answeredCount: Int
    public var statusCounts: [EvaluationStatus: Int]

    public init(session: StudySession, answeredCount: Int, statusCounts: [EvaluationStatus: Int]) {
        self.session = session
        self.answeredCount = answeredCount
        self.statusCounts = statusCounts
    }
}

/// Owns every persistent record and its migrations.
public protocol StudyRepository: Sendable {
    // Documents
    func saveDocument(_ document: StudyDocument) async throws
    func updateDocument(_ document: StudyDocument) async throws
    func document(id: DocumentID) async throws -> StudyDocument?
    func documents() async throws -> [StudyDocument]
    func documentSummaries() async throws -> [DocumentSummary]
    func saveImport(_ result: DocumentImportResult, document: StudyDocument) async throws
    func deleteDocument(id: DocumentID) async throws
    func setActiveSnapshot(_ snapshotId: SnapshotID, for documentId: DocumentID) async throws

    // Snapshots, sections, chunks
    func snapshot(id: SnapshotID) async throws -> DocumentSnapshot?
    func activeSnapshot(for documentId: DocumentID) async throws -> DocumentSnapshot?
    func snapshots(documentId: DocumentID) async throws -> [DocumentSnapshot]
    func sections(snapshotId: SnapshotID) async throws -> [DocumentSection]
    func section(id: SectionID) async throws -> DocumentSection?
    func chunks(snapshotId: SnapshotID) async throws -> [SourceChunk]
    func chunks(ids: [ChunkID]) async throws -> [SourceChunk]
    func searchChunkIds(query: String, snapshotId: SnapshotID, limit: Int) async throws -> [ChunkID]
    func isFullTextSearchSupported() async -> Bool

    // Scopes
    func saveScope(_ scope: StudyScope) async throws
    func scope(id: ScopeID) async throws -> StudyScope?
    func scopes(snapshotId: SnapshotID) async throws -> [StudyScope]

    // Topics
    func saveTopics(_ topics: [Topic]) async throws
    func topics(snapshotId: SnapshotID) async throws -> [Topic]
    func topic(id: TopicID) async throws -> Topic?

    // Sessions
    func saveSession(_ session: StudySession) async throws
    func updateSession(_ session: StudySession) async throws
    func session(id: SessionID) async throws -> StudySession?
    func sessions(documentId: DocumentID?) async throws -> [StudySession]
    func activeSession(for documentId: DocumentID) async throws -> StudySession?
    func sessionProgress(sessionId: SessionID) async throws -> SessionProgress?

    // Questions, attempts, evaluations
    func saveDraft(questionId: QuestionID, text: String) async throws
    func draftText(questionId: QuestionID) async throws -> String?
    func deleteDraft(questionId: QuestionID) async throws

    func saveQuestion(_ question: Question) async throws
    func question(id: QuestionID) async throws -> Question?
    func questions(sessionId: SessionID) async throws -> [Question]
    func questionHashes(snapshotId: SnapshotID) async throws -> Set<String>
    func saveAttempt(_ attempt: AnswerAttempt) async throws
    func updateAttempt(_ attempt: AnswerAttempt) async throws
    func attempts(questionId: QuestionID) async throws -> [AnswerAttempt]
    func latestAttempt(questionId: QuestionID) async throws -> AnswerAttempt?
    func saveEvaluation(_ evaluation: Evaluation) async throws
    func updateEvaluation(_ evaluation: Evaluation) async throws
    func deleteAttempt(id: AttemptID) async throws
    func evaluation(id: EvaluationID) async throws -> Evaluation?
    func evaluation(forAttempt attemptId: AttemptID) async throws -> Evaluation?

    // Progress and history
    func topicAttempts(snapshotId: SnapshotID) async throws -> [TopicAttempt]
    func sessionHistory(sessionId: SessionID) async throws -> [HistoryRecord]
    func history(filters: HistoryFilters) async throws -> [HistoryRecord]

    // Prompts
    func savePromptVersion(_ version: PromptVersion) async throws
    func promptVersions() async throws -> [PromptVersion]
    func promptVersion(id: PromptVersionID) async throws -> PromptVersion?
    func activePromptVersion() async throws -> PromptVersion?
    func setActivePromptVersion(_ id: PromptVersionID) async throws

    // Provider profiles
    func saveProviderProfile(_ profile: ProviderProfile) async throws
    func providerProfiles() async throws -> [ProviderProfile]
    func providerProfile(id: ProviderProfileID) async throws -> ProviderProfile?
    func deleteProviderProfile(id: ProviderProfileID) async throws
    func activeProviderProfile() async throws -> ProviderProfile?
    func setActiveProviderProfile(_ id: ProviderProfileID?) async throws

    // Speech profiles
    func saveSpeechProfile(_ profile: SpeechProfile) async throws
    func speechProfiles() async throws -> [SpeechProfile]
    func activeSpeechProfile() async throws -> SpeechProfile?
    func setActiveSpeechProfile(_ id: SpeechProfileID?) async throws
    func deleteSpeechProfile(id: SpeechProfileID) async throws

    // Danger zone
    func deleteAllStudyData() async throws
}

// MARK: - Prompt repository

/// Loads the active AGENT.md, supports reset and version tracking.
public protocol PromptRepository: Sendable {
    func activeVersion() async throws -> PromptVersion
    func versions() async throws -> [PromptVersion]
    func version(id: PromptVersionID) async throws -> PromptVersion?
    func save(content: String) async throws -> PromptVersion
    func restoreDefault() async throws -> PromptVersion
    func defaultContent() -> String
    /// Copy of the active content on disk, for user inspection.
    func activeContentFileURL() -> URL?
}
