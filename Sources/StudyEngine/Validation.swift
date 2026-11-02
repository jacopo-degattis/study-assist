import Foundation
import StudyDomain

/// Tunable limits for question generation, evaluation and hints.
public struct StudyEngineConfiguration: Sendable, Hashable {
    public var maximumGenerationAttempts: Int
    public var maximumEvidenceChunks: Int
    public var maximumEvidenceCharacters: Int
    /// Minimum fraction of an expected point's content words that must appear in
    /// its referenced passages for the point to count as locally supported.
    public var minimumPointSupport: Double
    public var maximumQuestionCharacters: Int
    public var questionTemperature: Double
    public var evaluationTemperature: Double
    public var hintTemperature: Double
    public var questionMaxOutputTokens: Int
    public var evaluationMaxOutputTokens: Int
    public var hintMaxOutputTokens: Int

    public init(
        maximumGenerationAttempts: Int = 3,
        maximumEvidenceChunks: Int = 4,
        maximumEvidenceCharacters: Int = 14_000,
        minimumPointSupport: Double = 0.4,
        maximumQuestionCharacters: Int = 600,
        questionTemperature: Double = 0.4,
        evaluationTemperature: Double = 0.0,
        hintTemperature: Double = 0.2,
        questionMaxOutputTokens: Int = 1_000,
        evaluationMaxOutputTokens: Int = 800,
        hintMaxOutputTokens: Int = 400
    ) {
        self.maximumGenerationAttempts = maximumGenerationAttempts
        self.maximumEvidenceChunks = maximumEvidenceChunks
        self.maximumEvidenceCharacters = maximumEvidenceCharacters
        self.minimumPointSupport = minimumPointSupport
        self.maximumQuestionCharacters = maximumQuestionCharacters
        self.questionTemperature = questionTemperature
        self.evaluationTemperature = evaluationTemperature
        self.hintTemperature = hintTemperature
        self.questionMaxOutputTokens = questionMaxOutputTokens
        self.evaluationMaxOutputTokens = evaluationMaxOutputTokens
        self.hintMaxOutputTokens = hintMaxOutputTokens
    }

    public static let `default` = StudyEngineConfiguration()
}

// MARK: - Payloads

struct QuestionPayload: Decodable {
    var topicId: String?
    var question: String?
    var expectedPoints: [PointPayload]?
    var sourceChunkIds: [String]?
    var answerability: String?

    struct PointPayload: Decodable {
        var id: String?
        var text: String?
        var sourceChunkIds: [String]?
    }
}

struct EvaluationPayload: Decodable {
    var status: String?
    var correctPointIds: [String]?
    var missingPointIds: [String]?
    var incorrectStatements: [String]?
    var feedback: String?
    var evidenceChunkIds: [String]?
    var needsClarification: Bool?
}

struct HintPayload: Decodable {
    var level: Int?
    var hint: String?
    var sourceChunkIds: [String]?
}

// MARK: - Validation

/// Local validation of the question contract.
///
/// A syntactically valid source id is necessary but not sufficient: each
/// expected point must also share real wording with the passage it cites.
public enum QuestionValidator {
    public struct Validated {
        public var text: String
        public var rubric: QuestionRubric
    }

    public static func validate(
        payloadData: Data,
        topic: Topic,
        evidence: [SourceChunk],
        existingHashes: Set<String>,
        configuration: StudyEngineConfiguration
    ) throws -> Validated {
        let payload: QuestionPayload
        do {
            payload = try JSONDecoder().decode(QuestionPayload.self, from: payloadData)
        } catch {
            throw AppError.validationFailed("The question JSON did not match the contract.")
        }

        guard let topicId = payload.topicId?.trimmingCharacters(in: .whitespacesAndNewlines), !topicId.isEmpty else {
            throw AppError.validationFailed("The question did not name its topic.")
        }
        guard topicId == topic.id.rawValue else {
            throw AppError.validationFailed("The question named a different topic than the one requested.")
        }
        guard let rawQuestion = payload.question else {
            throw AppError.validationFailed("The question text was missing.")
        }
        let questionText = TextUtilities.normalizeWhitespace(rawQuestion)
        guard questionText.count >= 12 else {
            throw AppError.validationFailed("The question was too short to be meaningful.")
        }
        guard questionText.count <= configuration.maximumQuestionCharacters else {
            throw AppError.validationFailed("The question was too long.")
        }
        guard TextUtilities.normalizeForComparison(questionText) != TextUtilities.normalizeForComparison(topic.title) else {
            throw AppError.validationFailed("The question repeated the topic title instead of asking something.")
        }

        let answerability = (payload.answerability ?? "").lowercased()
        guard answerability == Answerability.supported.rawValue else {
            throw AppError.insufficientEvidence("The model reported that the passages do not support a question on this topic.")
        }

        guard let points = payload.expectedPoints, !points.isEmpty else {
            throw AppError.validationFailed("The question had no expected answer points.")
        }
        guard points.count <= 6 else {
            throw AppError.validationFailed("The question had too many expected answer points.")
        }
        guard let declaredIds = payload.sourceChunkIds, !declaredIds.isEmpty else {
            throw AppError.validationFailed("The question cited no source passages.")
        }

        let authorized = Set(evidence.map { $0.id.rawValue })
        let textByChunk = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id.rawValue, $0.text) })

        for id in declaredIds where !authorized.contains(id) {
            throw AppError.validationFailed("The question cited a passage that was not supplied (\(id)).")
        }

        var expectedPoints: [ExpectedPoint] = []
        var usedIds: Set<String> = []
        var citedByPoints: Set<String> = []

        for (index, point) in points.enumerated() {
            guard let text = point.text.map(TextUtilities.normalizeWhitespace), !text.isEmpty else {
                throw AppError.validationFailed("An expected point had no text.")
            }
            guard text.count <= 500 else {
                throw AppError.validationFailed("An expected point was too long.")
            }
            let rawId = point.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pointId = rawId.isEmpty ? "p\(index + 1)" : rawId
            guard pointId.count <= 40, pointId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                throw AppError.validationFailed("An expected point had an unusable identifier.")
            }
            guard !usedIds.contains(pointId) else {
                throw AppError.validationFailed("Two expected points shared the identifier \(pointId).")
            }
            usedIds.insert(pointId)

            guard let pointChunkIds = point.sourceChunkIds, !pointChunkIds.isEmpty else {
                throw AppError.validationFailed("An expected point cited no passage.")
            }
            for id in pointChunkIds where !authorized.contains(id) {
                throw AppError.validationFailed("An expected point cited a passage that was not supplied (\(id)).")
            }
            citedByPoints.formUnion(pointChunkIds)

            let supportingText = pointChunkIds.compactMap { textByChunk[$0] }.joined(separator: "\n")
            let support = TextUtilities.containment(of: text, in: supportingText)
            guard support >= configuration.minimumPointSupport else {
                throw AppError.validationFailed(
                    "The expected point \"\(text.prefix(80))\" is not supported by the passage it cites (overlap \(String(format: "%.2f", support)))."
                )
            }

            expectedPoints.append(
                ExpectedPoint(
                    id: pointId,
                    text: text,
                    sourceChunkIds: pointChunkIds.map(ChunkID.init(rawValue:))
                )
            )
        }

        // Every point's evidence must be declared at question level as well.
        for id in citedByPoints where !declaredIds.contains(id) {
            throw AppError.validationFailed("A point cited a passage missing from the question's source list.")
        }

        let hash = TextUtilities.questionHash(questionText)
        guard !existingHashes.contains(hash) else {
            throw AppError.validationFailed("The question duplicated one already asked on this document.")
        }

        let rubric = QuestionRubric(
            expectedPoints: expectedPoints,
            sourceChunkIds: declaredIds.map(ChunkID.init(rawValue:)),
            answerability: .supported
        )
        return Validated(text: questionText, rubric: rubric)
    }
}

/// Local validation of the evaluation contract.
public enum EvaluationValidator {
    public struct Validated {
        public var status: EvaluationStatus
        public var correctPointIds: [String]
        public var missingPointIds: [String]
        public var incorrectStatements: [String]
        public var feedback: String
        public var evidenceChunkIds: [ChunkID]
    }

    public static func validate(
        payloadData: Data,
        question: Question,
        authorizedEvidence: [SourceChunk]
    ) throws -> Validated {
        let payload: EvaluationPayload
        do {
            payload = try JSONDecoder().decode(EvaluationPayload.self, from: payloadData)
        } catch {
            throw AppError.evaluationRejected("The assessment JSON did not match the contract.")
        }

        guard let rawStatus = payload.status?.lowercased(),
              let status = EvaluationStatus(rawValue: rawStatus) else {
            throw AppError.evaluationRejected("The assessment had no valid status.")
        }
        if payload.needsClarification == true {
            throw AppError.evaluationRejected("The model could not interpret the answer unambiguously.")
        }

        guard let feedback = payload.feedback.map(TextUtilities.normalizeWhitespace), !feedback.isEmpty else {
            throw AppError.evaluationRejected("The assessment had no feedback.")
        }
        guard feedback.count <= 1_500 else {
            throw AppError.evaluationRejected("The feedback was too long.")
        }

        let rubricIds = Set(question.rubric.expectedPoints.map(\.id))
        let correct = payload.correctPointIds ?? []
        let missing = payload.missingPointIds ?? []
        let incorrectStatements = (payload.incorrectStatements ?? [])
            .map(TextUtilities.normalizeWhitespace)
            .filter { !$0.isEmpty }

        for id in correct where !rubricIds.contains(id) {
            throw AppError.evaluationRejected("The assessment referenced an expected point that does not exist (\(id)).")
        }
        for id in missing where !rubricIds.contains(id) {
            throw AppError.evaluationRejected("The assessment referenced an expected point that does not exist (\(id)).")
        }
        guard Set(correct).isDisjoint(with: Set(missing)) else {
            throw AppError.evaluationRejected("The assessment marked the same point as both present and missing.")
        }
        guard Set(correct).count == correct.count, Set(missing).count == missing.count else {
            throw AppError.evaluationRejected("The assessment repeated an expected point.")
        }

        let authorizedIds = Set(authorizedEvidence.map(\.id))
        let evidenceIds = (payload.evidenceChunkIds ?? []).map(ChunkID.init(rawValue:))
        for id in evidenceIds where !authorizedIds.contains(id) {
            throw AppError.evaluationRejected("The assessment cited a passage that was not supplied.")
        }

        switch status {
        case .correct:
            guard Set(correct) == rubricIds, incorrectStatements.isEmpty else {
                throw AppError.evaluationRejected("A correct verdict requires every expected point and no incorrect statements.")
            }
        case .partial:
            guard !correct.isEmpty || !missing.isEmpty || !incorrectStatements.isEmpty else {
                throw AppError.evaluationRejected("A partial verdict must identify what was present or missing.")
            }
            guard Set(correct) != rubricIds || !incorrectStatements.isEmpty else {
                throw AppError.evaluationRejected("Every expected point was present, so the verdict cannot be partial.")
            }
        case .incorrect:
            if incorrectStatements.isEmpty, !correct.isEmpty {
                throw AppError.evaluationRejected("An incorrect verdict needs a wrong statement or no correct points.")
            }
        case .notEvaluable:
            break
        }

        if status.isEvaluable {
            guard !evidenceIds.isEmpty else {
                throw AppError.evaluationRejected("An evaluable verdict must cite the passages it relied on.")
            }
            let rubricChunks = Set(question.rubric.sourceChunkIds)
            guard !Set(evidenceIds).isDisjoint(with: rubricChunks) else {
                throw AppError.evaluationRejected("The assessment cited passages unrelated to the question.")
            }
        }

        return Validated(
            status: status,
            correctPointIds: correct,
            missingPointIds: missing,
            incorrectStatements: incorrectStatements,
            feedback: feedback,
            evidenceChunkIds: evidenceIds
        )
    }
}

/// Local validation of hints.
public enum HintValidator {
    public struct Validated {
        public var level: Int
        public var text: String
        public var evidenceChunkIds: [ChunkID]
    }

    public static func validate(
        payloadData: Data,
        question: Question,
        authorizedEvidence: [SourceChunk],
        requestedLevel: Int
    ) throws -> Validated {
        let payload: HintPayload
        do {
            payload = try JSONDecoder().decode(HintPayload.self, from: payloadData)
        } catch {
            throw AppError.validationFailed("The hint JSON did not match the contract.")
        }
        guard let text = payload.hint.map(TextUtilities.normalizeWhitespace), !text.isEmpty else {
            throw AppError.validationFailed("The hint was empty.")
        }
        guard text.count <= 600 else {
            throw AppError.validationFailed("The hint was too long.")
        }
        let level = min(max(payload.level ?? requestedLevel, 1), 2)

        let authorizedIds = Set(authorizedEvidence.map(\.id))
        let evidenceIds = (payload.sourceChunkIds ?? []).map(ChunkID.init(rawValue:))
        for id in evidenceIds where !authorizedIds.contains(id) {
            throw AppError.validationFailed("The hint cited a passage that was not supplied.")
        }
        guard !evidenceIds.isEmpty else {
            throw AppError.validationFailed("The hint cited no passage.")
        }

        // A first hint must not give away an expected point.
        if level == 1 {
            for point in question.rubric.expectedPoints {
                let overlap = TextUtilities.containment(of: point.text, in: text)
                if overlap > 0.85 {
                    throw AppError.validationFailed("The first hint revealed an expected answer point.")
                }
            }
        }
        return Validated(level: level, text: text, evidenceChunkIds: evidenceIds)
    }
}
