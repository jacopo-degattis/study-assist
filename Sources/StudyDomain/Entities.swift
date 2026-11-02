import Foundation

// MARK: - Documents

public enum DocumentFileType: String, Codable, Sendable, CaseIterable {
    case pdf
    case docx

    public var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .docx: return "DOCX"
        }
    }

    public var fileExtensions: [String] {
        switch self {
        case .pdf: return ["pdf"]
        case .docx: return ["docx"]
        }
    }
}

public enum DocumentState: String, Codable, Sendable {
    case importing
    case ready
    case failed
}

/// How a chunk of text was obtained from the source file.
public enum ExtractionMethod: String, Codable, Sendable {
    /// Text layer extracted directly from the PDF.
    case pdfText
    /// Text obtained by running on-device OCR over a rendered page.
    case pdfOCR
    /// Text extracted from the Office Open XML package.
    case docxXML
}

/// Where a chunk sits in the source document, for the source viewer.
public struct SourceLocation: Codable, Hashable, Sendable {
    public var pageNumber: Int?
    public var paragraphIndex: Int?
    /// Last paragraph covered by the chunk, when it spans several paragraphs.
    public var endParagraphIndex: Int?
    public var sectionTitle: String?

    public init(pageNumber: Int? = nil, paragraphIndex: Int? = nil, endParagraphIndex: Int? = nil, sectionTitle: String? = nil) {
        self.pageNumber = pageNumber
        self.paragraphIndex = paragraphIndex
        self.endParagraphIndex = endParagraphIndex
        self.sectionTitle = sectionTitle
    }

    public var shortDescription: String {
        if let pageNumber { return "Page \(pageNumber)" }
        if let paragraphIndex {
            if let endParagraphIndex, endParagraphIndex > paragraphIndex {
                return "Paragraphs \(paragraphIndex + 1)–\(endParagraphIndex + 1)"
            }
            return "Paragraph \(paragraphIndex + 1)"
        }
        return "Document"
    }
}

/// Quality information gathered while importing, surfaced to the user.
public struct DocumentQuality: Codable, Hashable, Sendable {
    public var pagesProcessed: Int
    public var pagesRequiringOCR: Int
    public var pagesUnreadable: Int
    public var paragraphsExtracted: Int
    public var charactersExtracted: Int
    public var warnings: [String]

    public init(
        pagesProcessed: Int = 0,
        pagesRequiringOCR: Int = 0,
        pagesUnreadable: Int = 0,
        paragraphsExtracted: Int = 0,
        charactersExtracted: Int = 0,
        warnings: [String] = []
    ) {
        self.pagesProcessed = pagesProcessed
        self.pagesRequiringOCR = pagesRequiringOCR
        self.pagesUnreadable = pagesUnreadable
        self.paragraphsExtracted = paragraphsExtracted
        self.charactersExtracted = charactersExtracted
        self.warnings = warnings
    }

    public var summary: String {
        var parts: [String] = []
        if pagesProcessed > 0 {
            parts.append("\(pagesProcessed) page\(pagesProcessed == 1 ? "" : "s") processed")
        } else {
            parts.append("\(paragraphsExtracted) paragraph\(paragraphsExtracted == 1 ? "" : "s") extracted")
        }
        if pagesRequiringOCR > 0 {
            parts.append("\(pagesRequiringOCR) required OCR")
        }
        if pagesUnreadable > 0 {
            parts.append("\(pagesUnreadable) contain unreadable material")
        }
        return parts.joined(separator: "; ")
    }
}

public struct StudyDocument: Codable, Hashable, Sendable, Identifiable {
    public var id: DocumentID
    public var name: String
    public var fileType: DocumentFileType
    public var storedFileName: String
    public var sha256: String
    public var importedAt: Date
    public var state: DocumentState
    public var language: String?
    public var parserVersion: String
    public var activeSnapshotId: SnapshotID?

    public init(
        id: DocumentID = DocumentID(),
        name: String,
        fileType: DocumentFileType,
        storedFileName: String,
        sha256: String,
        importedAt: Date = Date(),
        state: DocumentState,
        language: String? = nil,
        parserVersion: String,
        activeSnapshotId: SnapshotID? = nil
    ) {
        self.id = id
        self.name = name
        self.fileType = fileType
        self.storedFileName = storedFileName
        self.sha256 = sha256
        self.importedAt = importedAt
        self.state = state
        self.language = language
        self.parserVersion = parserVersion
        self.activeSnapshotId = activeSnapshotId
    }
}

public struct DocumentSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: SnapshotID
    public var documentId: DocumentID
    public var version: Int
    public var textHash: String
    public var quality: DocumentQuality
    public var createdAt: Date

    public init(
        id: SnapshotID = SnapshotID(),
        documentId: DocumentID,
        version: Int,
        textHash: String,
        quality: DocumentQuality,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.documentId = documentId
        self.version = version
        self.textHash = textHash
        self.quality = quality
        self.createdAt = createdAt
    }
}

public struct DocumentSection: Codable, Hashable, Sendable, Identifiable {
    public var id: SectionID
    public var snapshotId: SnapshotID
    public var title: String
    public var level: Int
    public var order: Int
    public var location: SourceLocation

    public init(
        id: SectionID = SectionID(),
        snapshotId: SnapshotID,
        title: String,
        level: Int,
        order: Int,
        location: SourceLocation = SourceLocation()
    ) {
        self.id = id
        self.snapshotId = snapshotId
        self.title = title
        self.level = level
        self.order = order
        self.location = location
    }
}

public struct SourceChunk: Codable, Hashable, Sendable, Identifiable {
    public var id: ChunkID
    public var snapshotId: SnapshotID
    public var text: String
    public var sectionId: SectionID?
    public var location: SourceLocation
    /// Character offsets of this chunk in the snapshot's normalized text.
    public var startOffset: Int
    public var endOffset: Int
    public var extractionMethod: ExtractionMethod
    /// A relative confidence in [0, 1]; lower for OCR-derived and dubious content.
    public var quality: Double
    /// False when the chunk must not be used as evidence (unreadable or unreliable).
    public var isUsableAsEvidence: Bool
    public var order: Int

    public init(
        id: ChunkID = ChunkID(),
        snapshotId: SnapshotID,
        text: String,
        sectionId: SectionID? = nil,
        location: SourceLocation = SourceLocation(),
        startOffset: Int,
        endOffset: Int,
        extractionMethod: ExtractionMethod,
        quality: Double = 1.0,
        isUsableAsEvidence: Bool = true,
        order: Int
    ) {
        self.id = id
        self.snapshotId = snapshotId
        self.text = text
        self.sectionId = sectionId
        self.location = location
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.extractionMethod = extractionMethod
        self.quality = quality
        self.isUsableAsEvidence = isUsableAsEvidence
        self.order = order
    }
}

/// The complete, validated result of importing one file.
public struct DocumentImportResult: Sendable {
    public var documentName: String
    public var fileType: DocumentFileType
    public var fileHash: String
    public var textHash: String
    public var storedFileName: String
    public var snapshot: DocumentSnapshot
    public var sections: [DocumentSection]
    public var chunks: [SourceChunk]
    public var fullText: String
    public var language: String?
    public var parserVersion: String

    public init(
        documentName: String,
        fileType: DocumentFileType,
        fileHash: String,
        textHash: String,
        storedFileName: String,
        snapshot: DocumentSnapshot,
        sections: [DocumentSection],
        chunks: [SourceChunk],
        fullText: String,
        language: String?,
        parserVersion: String
    ) {
        self.documentName = documentName
        self.fileType = fileType
        self.fileHash = fileHash
        self.textHash = textHash
        self.storedFileName = storedFileName
        self.snapshot = snapshot
        self.sections = sections
        self.chunks = chunks
        self.fullText = fullText
        self.language = language
        self.parserVersion = parserVersion
    }
}

public struct ImportProgress: Sendable, Hashable {
    public var phase: String
    public var fraction: Double?

    public init(phase: String, fraction: Double? = nil) {
        self.phase = phase
        self.fraction = fraction
    }
}

// MARK: - Topics and study records

public struct Topic: Codable, Hashable, Sendable, Identifiable {
    public var id: TopicID
    public var snapshotId: SnapshotID
    public var title: String
    public var sourceChunkIds: [ChunkID]
    public var order: Int

    public init(
        id: TopicID = TopicID(),
        snapshotId: SnapshotID,
        title: String,
        sourceChunkIds: [ChunkID],
        order: Int
    ) {
        self.id = id
        self.snapshotId = snapshotId
        self.title = title
        self.sourceChunkIds = sourceChunkIds
        self.order = order
    }
}

public enum SessionMode: String, Codable, Sendable {
    case fullStudy
    case review

    public var displayName: String {
        switch self {
        case .fullStudy: return "Full study"
        case .review: return "Review weak areas"
        }
    }
}

public enum SessionState: String, Codable, Sendable {
    case active
    case completed
}

public struct StudySession: Codable, Hashable, Sendable, Identifiable {
    public var id: SessionID
    public var documentId: DocumentID
    public var snapshotId: SnapshotID
    public var startedAt: Date
    public var finishedAt: Date?
    public var mode: SessionMode
    public var promptVersionId: PromptVersionID
    public var modelProfileId: ProviderProfileID?
    public var state: SessionState
    /// The scope the session started with. Never rewritten.
    public var scopeId: ScopeID?
    /// The scope used for the next question. Changing focus updates only this.
    public var currentScopeId: ScopeID?

    public init(
        id: SessionID = SessionID(),
        documentId: DocumentID,
        snapshotId: SnapshotID,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        mode: SessionMode,
        promptVersionId: PromptVersionID,
        modelProfileId: ProviderProfileID? = nil,
        state: SessionState = .active,
        scopeId: ScopeID? = nil,
        currentScopeId: ScopeID? = nil
    ) {
        self.id = id
        self.documentId = documentId
        self.snapshotId = snapshotId
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.mode = mode
        self.promptVersionId = promptVersionId
        self.modelProfileId = modelProfileId
        self.state = state
        self.scopeId = scopeId
        self.currentScopeId = currentScopeId
    }

    public var isActive: Bool { state == .active && finishedAt == nil }
}

/// One essential fact the student is expected to express, tied to real passages.
public struct ExpectedPoint: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var sourceChunkIds: [ChunkID]

    public init(id: String, text: String, sourceChunkIds: [ChunkID]) {
        self.id = id
        self.text = text
        self.sourceChunkIds = sourceChunkIds
    }
}

public enum Answerability: String, Codable, Sendable {
    case supported
    case unsupported

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Answerability(rawValue: raw.lowercased()) ?? .unsupported
    }
}

/// The frozen rubric stored with a question. Never regenerated after the fact.
public struct QuestionRubric: Codable, Hashable, Sendable {
    public var expectedPoints: [ExpectedPoint]
    public var sourceChunkIds: [ChunkID]
    public var answerability: Answerability

    public init(expectedPoints: [ExpectedPoint], sourceChunkIds: [ChunkID], answerability: Answerability) {
        self.expectedPoints = expectedPoints
        self.sourceChunkIds = sourceChunkIds
        self.answerability = answerability
    }
}

public struct Question: Codable, Hashable, Sendable, Identifiable {
    public var id: QuestionID
    public var sessionId: SessionID
    public var topicId: TopicID
    public var text: String
    public var rubric: QuestionRubric
    public var createdAt: Date
    public var normalizedTextHash: String
    /// The scope this question was generated in. Frozen with the question.
    public var scopeId: ScopeID?

    public init(
        id: QuestionID = QuestionID(),
        sessionId: SessionID,
        topicId: TopicID,
        text: String,
        rubric: QuestionRubric,
        createdAt: Date = Date(),
        normalizedTextHash: String,
        scopeId: ScopeID? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.topicId = topicId
        self.text = text
        self.rubric = rubric
        self.createdAt = createdAt
        self.normalizedTextHash = normalizedTextHash
        self.scopeId = scopeId
    }

    public var sourceChunkIds: [ChunkID] { rubric.sourceChunkIds }
}

public enum AnswerInputMode: String, Codable, Sendable {
    case typed
    case speech
}

public struct AnswerAttempt: Codable, Hashable, Sendable, Identifiable {
    public var id: AttemptID
    public var questionId: QuestionID
    public var text: String
    public var inputMode: AnswerInputMode
    public var rawTranscript: String?
    public var createdAt: Date
    public var evaluationId: EvaluationID?

    public init(
        id: AttemptID = AttemptID(),
        questionId: QuestionID,
        text: String,
        inputMode: AnswerInputMode,
        rawTranscript: String? = nil,
        createdAt: Date = Date(),
        evaluationId: EvaluationID? = nil
    ) {
        self.id = id
        self.questionId = questionId
        self.text = text
        self.inputMode = inputMode
        self.rawTranscript = rawTranscript
        self.createdAt = createdAt
        self.evaluationId = evaluationId
    }
}

public enum EvaluationStatus: String, Codable, Sendable, CaseIterable {
    case correct
    case partial
    case incorrect
    case notEvaluable = "not_evaluable"

    public var displayName: String {
        switch self {
        case .correct: return "Correct"
        case .partial: return "Partially correct"
        case .incorrect: return "Incorrect"
        case .notEvaluable: return "Not evaluable"
        }
    }

    public var isEvaluable: Bool { self != .notEvaluable }

    /// Internal review score. `not_evaluable` has no score at all.
    public var reviewScore: Int? {
        switch self {
        case .correct: return 2
        case .partial: return 1
        case .incorrect: return 0
        case .notEvaluable: return nil
        }
    }
}

public struct EvaluationOverride: Codable, Hashable, Sendable {
    public var status: EvaluationStatus
    public var note: String?
    public var overriddenAt: Date

    public init(status: EvaluationStatus, note: String? = nil, overriddenAt: Date = Date()) {
        self.status = status
        self.note = note
        self.overriddenAt = overriddenAt
    }
}

public struct Evaluation: Codable, Hashable, Sendable, Identifiable {
    public var id: EvaluationID
    public var attemptId: AttemptID
    public var status: EvaluationStatus
    public var feedback: String
    public var correctPointIds: [String]
    public var missingPointIds: [String]
    public var incorrectStatements: [String]
    public var evidenceChunkIds: [ChunkID]
    public var providerProfileId: ProviderProfileID?
    public var modelId: String?
    public var promptVersionId: PromptVersionID?
    public var createdAt: Date
    /// Present when the app itself could not evaluate; explains why.
    public var notEvaluableReason: String?
    public var userOverride: EvaluationOverride?

    public init(
        id: EvaluationID = EvaluationID(),
        attemptId: AttemptID,
        status: EvaluationStatus,
        feedback: String,
        correctPointIds: [String] = [],
        missingPointIds: [String] = [],
        incorrectStatements: [String] = [],
        evidenceChunkIds: [ChunkID] = [],
        providerProfileId: ProviderProfileID? = nil,
        modelId: String? = nil,
        promptVersionId: PromptVersionID? = nil,
        createdAt: Date = Date(),
        notEvaluableReason: String? = nil,
        userOverride: EvaluationOverride? = nil
    ) {
        self.id = id
        self.attemptId = attemptId
        self.status = status
        self.feedback = feedback
        self.correctPointIds = correctPointIds
        self.missingPointIds = missingPointIds
        self.incorrectStatements = incorrectStatements
        self.evidenceChunkIds = evidenceChunkIds
        self.providerProfileId = providerProfileId
        self.modelId = modelId
        self.promptVersionId = promptVersionId
        self.createdAt = createdAt
        self.notEvaluableReason = notEvaluableReason
        self.userOverride = userOverride
    }

    /// The outcome shown to the student: their override wins, the original stays stored.
    public var effectiveStatus: EvaluationStatus {
        userOverride?.status ?? status
    }
}

// MARK: - Prompts and profiles

public struct PromptVersion: Codable, Hashable, Sendable, Identifiable {
    public var id: PromptVersionID
    public var content: String
    public var contentHash: String
    public var editedAt: Date
    public var isDefault: Bool

    public init(
        id: PromptVersionID = PromptVersionID(),
        content: String,
        contentHash: String,
        editedAt: Date = Date(),
        isDefault: Bool
    ) {
        self.id = id
        self.content = content
        self.contentHash = contentHash
        self.editedAt = editedAt
        self.isDefault = isDefault
    }
}

public enum ProviderAPIStyle: String, Codable, Sendable, CaseIterable {
    case chatCompletions = "chat_completions"
    case responses

    public var displayName: String {
        switch self {
        case .chatCompletions: return "Chat Completions"
        case .responses: return "Responses"
        }
    }
}

/// Non-secret provider configuration. Secrets are kept in the Keychain.
public struct ProviderProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: ProviderProfileID
    public var name: String
    public var baseURL: String
    public var apiStyle: ProviderAPIStyle
    public var modelId: String
    public var keychainRef: String?
    public var requiresAuthentication: Bool
    /// Extra headers the user explicitly authorized (values are stored in the Keychain-backed secret blob when sensitive).
    public var extraHeaders: [String: String]
    public var timeoutSeconds: Double
    public var maxRetries: Int
    public var createdAt: Date
    public var lastConnectionTest: Date?
    public var lastConnectionSucceeded: Bool?

    public init(
        id: ProviderProfileID = ProviderProfileID(),
        name: String,
        baseURL: String,
        apiStyle: ProviderAPIStyle = .chatCompletions,
        modelId: String,
        keychainRef: String? = nil,
        requiresAuthentication: Bool = true,
        extraHeaders: [String: String] = [:],
        timeoutSeconds: Double = 60,
        maxRetries: Int = 1,
        createdAt: Date = Date(),
        lastConnectionTest: Date? = nil,
        lastConnectionSucceeded: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiStyle = apiStyle
        self.modelId = modelId
        self.keychainRef = keychainRef
        self.requiresAuthentication = requiresAuthentication
        self.extraHeaders = extraHeaders
        self.timeoutSeconds = timeoutSeconds
        self.maxRetries = maxRetries
        self.createdAt = createdAt
        self.lastConnectionTest = lastConnectionTest
        self.lastConnectionSucceeded = lastConnectionSucceeded
    }
}

public enum SpeechEngine: String, Codable, Sendable, CaseIterable {
    case appleOnDevice
    case parakeetUltra
    case parakeetTDTv3
    case parakeetTDTv2
    case parakeetTDTCTC110M
    case parakeetJapanese
    case whisperLargeV3Turbo
    case whisperLargeV3TurboCompressed
    case whisperSmall
    case customEndpoint

    public var displayName: String {
        switch self {
        case .appleOnDevice: return "Apple on-device"
        case .parakeetUltra: return "Parakeet Ultra"
        case .parakeetTDTv3: return "Parakeet TDT v3"
        case .parakeetTDTv2: return "Parakeet TDT v2"
        case .parakeetTDTCTC110M: return "Parakeet TDT-CTC 110M"
        case .parakeetJapanese: return "Parakeet Japanese"
        case .whisperLargeV3Turbo: return "Whisper Large v3 Turbo"
        case .whisperLargeV3TurboCompressed: return "Whisper Large v3 Turbo (compressed)"
        case .whisperSmall: return "Whisper Small"
        case .customEndpoint: return "Custom STT endpoint"
        }
    }

    public var isLocal: Bool {
        switch self {
        case .customEndpoint: return false
        default: return true
        }
    }

    /// The languages this build can honestly claim for the engine.
    public var supportedLanguageNote: String {
        switch self {
        case .appleOnDevice:
            return "Availability depends on macOS language assets and OS version."
        case .parakeetUltra:
            return "Multilingual (25 European languages) through Parakeet Unified."
        case .parakeetTDTv3:
            return "Multilingual, 25 European languages."
        case .parakeetTDTv2:
            return "English-oriented: do not rely on it for Italian or other languages."
        case .parakeetTDTCTC110M:
            return "English; small model."
        case .parakeetJapanese:
            return "Japanese only."
        case .whisperLargeV3Turbo:
            return "Broad multilingual coverage; Apple Silicon recommended."
        case .whisperLargeV3TurboCompressed:
            return "Compressed build; only offered when the pinned runtime can load it."
        case .whisperSmall:
            return "Lighter multilingual model."
        case .customEndpoint:
            return "Transcription quality and language support depend on the endpoint."
        }
    }
}

public struct SpeechProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: SpeechProfileID
    public var engine: SpeechEngine
    public var modelId: String?
    public var isLocal: Bool
    public var keychainRef: String?
    public var language: String?
    public var remoteBaseURL: String?
    public var createdAt: Date

    public init(
        id: SpeechProfileID = SpeechProfileID(),
        engine: SpeechEngine,
        modelId: String? = nil,
        isLocal: Bool? = nil,
        keychainRef: String? = nil,
        language: String? = nil,
        remoteBaseURL: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.engine = engine
        self.modelId = modelId
        self.isLocal = isLocal ?? engine.isLocal
        self.keychainRef = keychainRef
        self.language = language
        self.remoteBaseURL = remoteBaseURL
        self.createdAt = createdAt
    }
}
