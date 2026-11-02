import Foundation
import StudyDomain
import StudyRetrieval
import StudyPrompts
import StudyProviders
import StudyPersistence

// MARK: - Public value types

public struct PreparedQuestion: Sendable {
    public var question: Question
    public var topic: Topic
    public var evidence: [SourceChunk]
    public var topicPerformance: TopicPerformance?
    public var answeredCount: Int
    public var topicCount: Int

    public init(question: Question, topic: Topic, evidence: [SourceChunk], topicPerformance: TopicPerformance?, answeredCount: Int, topicCount: Int) {
        self.question = question
        self.topic = topic
        self.evidence = evidence
        self.topicPerformance = topicPerformance
        self.answeredCount = answeredCount
        self.topicCount = topicCount
    }
}

public struct AnswerFeedback: Sendable {
    public var question: Question
    public var topic: Topic?
    public var attempt: AnswerAttempt
    public var evaluation: Evaluation
    public var evidence: [SourceChunk]

    public init(question: Question, topic: Topic?, attempt: AnswerAttempt, evaluation: Evaluation, evidence: [SourceChunk]) {
        self.question = question
        self.topic = topic
        self.attempt = attempt
        self.evaluation = evaluation
        self.evidence = evidence
    }

    public var canRetryEvaluation: Bool { evaluation.status == .notEvaluable }
}

public struct Hint: Sendable {
    public var level: Int
    public var text: String
    public var evidence: [SourceChunk]

    public init(level: Int, text: String, evidence: [SourceChunk]) {
        self.level = level
        self.text = text
        self.evidence = evidence
    }
}

public struct Solution: Sendable {
    public var expectedPoints: [ExpectedPoint]
    public var evidence: [SourceChunk]

    public init(expectedPoints: [ExpectedPoint], evidence: [SourceChunk]) {
        self.expectedPoints = expectedPoints
        self.evidence = evidence
    }
}

public struct SessionOverview: Sendable {
    public var answeredCount: Int
    public var topicCount: Int
    public var statusCounts: [EvaluationStatus: Int]

    public init(answeredCount: Int, topicCount: Int, statusCounts: [EvaluationStatus: Int]) {
        self.answeredCount = answeredCount
        self.topicCount = topicCount
        self.statusCounts = statusCounts
    }
}

public struct SessionSnapshot: Sendable {
    public var session: StudySession
    public var document: StudyDocument
    public var snapshot: DocumentSnapshot
    public var overview: SessionOverview
    public var question: Question?
    public var topic: Topic?
    public var draft: String
    public var attempt: AnswerAttempt?
    public var evaluation: Evaluation?
    public var evidence: [SourceChunk]
    /// The focus currently in force in this session (nil only for legacy rows).
    public var currentScope: StudyScope?
}

// MARK: - Engine

/// Orchestrates question selection, generation, evaluation and hints.
///
/// The engine keeps no authoritative state of its own: sessions, questions and
/// results live in the repository, so a crash or relaunch resumes safely.
public actor StudyEngine {
    private let repository: any StudyRepository
    private let retriever: any EvidenceRetriever
    private let prompts: any PromptRepository
    private let providerResolver: @Sendable (ProviderProfileID?) async throws -> any LLMProvider
    private let configuration: StudyEngineConfiguration
    private let scopeResolver: StudyScopeResolver

    private var providerCache: [SessionID: any LLMProvider] = [:]
    private var promptCache: [PromptVersionID: String] = [:]

    public init(
        repository: any StudyRepository,
        retriever: any EvidenceRetriever,
        prompts: any PromptRepository,
        providerResolver: @escaping @Sendable (ProviderProfileID?) async throws -> any LLMProvider,
        configuration: StudyEngineConfiguration = .default
    ) {
        self.repository = repository
        self.retriever = retriever
        self.prompts = prompts
        self.providerResolver = providerResolver
        self.configuration = configuration
        self.scopeResolver = StudyScopeResolver(repository: repository)
    }

    public var engineConfiguration: StudyEngineConfiguration { configuration }

    // MARK: Sessions

    public func activeSession(for documentId: DocumentID) async throws -> StudySession? {
        try await repository.activeSession(for: documentId)
    }

    public func session(id: SessionID) async throws -> StudySession? {
        try await repository.session(id: id)
    }

    public func startSession(documentId: DocumentID, mode: SessionMode, scopeId: ScopeID? = nil) async throws -> StudySession {
        guard let document = try await repository.document(id: documentId) else {
            throw AppError.documentUnreadable("The document is no longer in the library.")
        }
        guard let snapshotId = document.activeSnapshotId,
              let snapshot = try await repository.snapshot(id: snapshotId) else {
            throw AppError.documentNoActiveSnapshot
        }
        let topics = try await ensureTopics(snapshot: snapshot)
        guard !topics.isEmpty else {
            throw AppError.insufficientEvidence("No usable topics were found in this document.")
        }

        // Every session carries an immutable scope with an explicit allowlist.
        let scope: StudyScope
        if let scopeId {
            guard let existing = try await repository.scope(id: scopeId), existing.snapshotId == snapshotId else {
                throw AppError.invalidStateTransition("The selected focus does not belong to this document version.")
            }
            scope = existing
        } else {
            scope = try await scopeResolver.fullDocumentScope(snapshotId: snapshotId)
        }

        // Starting a new session closes an interrupted one, keeping its history.
        if var existing = try await repository.activeSession(for: documentId) {
            existing.state = .completed
            existing.finishedAt = existing.finishedAt ?? Date()
            try await repository.updateSession(existing)
            providerCache[existing.id] = nil
        }

        let promptVersion = try await prompts.activeVersion()
        let profile = try await repository.activeProviderProfile()
        let session = StudySession(
            documentId: documentId,
            snapshotId: snapshotId,
            mode: mode,
            promptVersionId: promptVersion.id,
            modelProfileId: profile?.id,
            state: .active,
            scopeId: scope.id,
            currentScopeId: scope.id
        )
        try await repository.saveSession(session)
        promptCache[promptVersion.id] = promptVersion.content
        return session
    }

    public func finishSession(sessionId: SessionID) async throws -> SessionSummary {
        guard var session = try await repository.session(id: sessionId) else {
            throw AppError.invalidStateTransition("The session no longer exists.")
        }
        if session.state == .active {
            session.state = .completed
            session.finishedAt = Date()
            try await repository.updateSession(session)
        }
        providerCache[sessionId] = nil

        let progress = try await repository.sessionProgress(sessionId: sessionId)
        let scope = try await currentScope(for: session)
        let performances = try await topicPerformances(snapshotId: session.snapshotId, scope: scope)
        return SessionSummary(
            answeredQuestions: progress?.answeredCount ?? 0,
            statusCounts: progress?.statusCounts ?? [:],
            weakTopics: performances.filter { $0.mastery == .weak || $0.mastery == .needsReinforcement }
        )
    }

    public func overview(sessionId: SessionID) async throws -> SessionOverview {
        guard let session = try await repository.session(id: sessionId) else {
            throw AppError.invalidStateTransition("The session no longer exists.")
        }
        let scope = try await currentScope(for: session)
        let topics = try await scopedTopics(session: session, scope: scope)
        let progress = try await repository.sessionProgress(sessionId: sessionId)
        return SessionOverview(
            answeredCount: progress?.answeredCount ?? 0,
            topicCount: topics.count,
            statusCounts: progress?.statusCounts ?? [:]
        )
    }

    public func sessionSnapshot(sessionId: SessionID) async throws -> SessionSnapshot {
        guard let session = try await repository.session(id: sessionId) else {
            throw AppError.invalidStateTransition("The session no longer exists.")
        }
        guard let document = try await repository.document(id: session.documentId) else {
            throw AppError.documentUnreadable("The document is no longer in the library.")
        }
        guard let snapshot = try await repository.snapshot(id: session.snapshotId) else {
            throw AppError.documentNoActiveSnapshot
        }
        let questions = try await repository.questions(sessionId: sessionId)
        let question = questions.last
        var topic: Topic?
        var attempt: AnswerAttempt?
        var evaluation: Evaluation?
        var evidence: [SourceChunk] = []
        var draft = ""

        if let question {
            topic = try await repository.topic(id: question.topicId)
            attempt = try await repository.latestAttempt(questionId: question.id)
            if let attempt {
                if let evaluationId = attempt.evaluationId {
                    evaluation = try await repository.evaluation(id: evaluationId)
                }
                if evaluation == nil {
                    evaluation = try await repository.evaluation(forAttempt: attempt.id)
                }
            }
            evidence = try await retriever.evidence(forChunkIds: question.rubric.sourceChunkIds, in: session.snapshotId)
            draft = try await repository.draftText(questionId: question.id) ?? ""
        }
        if attempt != nil, evaluation != nil {
            draft = ""
        }

        let currentScope = try await currentScope(for: session)
        let topics = try await scopedTopics(session: session, scope: currentScope)
        let progress = try await repository.sessionProgress(sessionId: sessionId)
        return SessionSnapshot(
            session: session,
            document: document,
            snapshot: snapshot,
            overview: SessionOverview(
                answeredCount: progress?.answeredCount ?? 0,
                topicCount: topics.count,
                statusCounts: progress?.statusCounts ?? [:]
            ),
            question: question,
            topic: topic,
            draft: draft,
            attempt: attempt,
            evaluation: evaluation,
            evidence: evidence,
            currentScope: currentScope
        )
    }

    public func saveDraft(questionId: QuestionID, text: String) async throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await repository.deleteDraft(questionId: questionId)
        } else {
            try await repository.saveDraft(questionId: questionId, text: text)
        }
    }

    // MARK: Question generation

    public func nextQuestion(sessionId: SessionID) async throws -> PreparedQuestion {
        guard let session = try await repository.session(id: sessionId), session.isActive else {
            throw AppError.invalidStateTransition("The session is not active.")
        }
        guard let snapshot = try await repository.snapshot(id: session.snapshotId) else {
            throw AppError.documentNoActiveSnapshot
        }
        _ = try await ensureTopics(snapshot: snapshot)
        let scope = try await currentScope(for: session)
        let topics = try await scopedTopics(session: session, scope: scope)
        guard !topics.isEmpty else {
            throw AppError.insufficientEvidence(
                scope.map { "No usable material was found inside the focus “\($0.displayTitle)”." }
                    ?? "No topic with usable source passages was found."
            )
        }

        let asked = try await repository.questions(sessionId: sessionId)
        var askedCounts: [TopicID: Int] = [:]
        for question in asked { askedCounts[question.topicId, default: 0] += 1 }
        var existingHashes = try await repository.questionHashes(snapshotId: session.snapshotId)
        let performances = session.mode == .review
            ? try await topicPerformances(snapshotId: session.snapshotId, scope: scope)
            : []

        let provider = try await provider(for: session)
        let agentInstructions = try await agentPrompt(for: session)

        var excluded: Set<TopicID> = []
        var failures: [String] = []

        for _ in 0..<max(1, configuration.maximumGenerationAttempts) {
            guard let topic = selectTopic(
                topics: topics,
                askedCounts: askedCounts,
                performances: performances,
                mode: session.mode,
                excluding: excluded
            ) else { break }
            excluded.insert(topic.id)

            let evidence = try await retriever.evidence(for: topic, in: session.snapshotId)
            guard !evidence.isEmpty else {
                failures.append("No usable passages for topic \"\(topic.title)\".")
                continue
            }
            let trimmed = Array(evidence.prefix(configuration.maximumEvidenceChunks))
            var request = PromptBuilder.questionRequest(
                agentInstructions: agentInstructions,
                topic: topic,
                evidence: trimmed,
                configuration: configuration
            )
            request.conversationID = sessionId.rawValue

            do {
                let completion = try await provider.complete(request)
                guard let data = JSONExtraction.objectData(from: completion.text) else {
                    throw AppError.validationFailed("The model response was not a JSON object.")
                }
                let validated = try QuestionValidator.validate(
                    payloadData: data,
                    topic: topic,
                    evidence: trimmed,
                    existingHashes: existingHashes,
                    configuration: configuration
                )
                // A focus change while the model was working must not attach the
                // old question to the new scope.
                guard let refreshed = try await repository.session(id: sessionId),
                      refreshed.currentScopeId == session.currentScopeId else {
                    throw AppError.operationCancelled
                }
                let question = Question(
                    sessionId: sessionId,
                    topicId: topic.id,
                    text: validated.text,
                    rubric: validated.rubric,
                    normalizedTextHash: TextUtilities.questionHash(validated.text),
                    scopeId: scope?.id
                )
                try await repository.saveQuestion(question)
                existingHashes.insert(question.normalizedTextHash)
                let performance = performances.first { $0.topic.id == topic.id }
                return PreparedQuestion(
                    question: question,
                    topic: topic,
                    evidence: trimmed,
                    topicPerformance: performance,
                    answeredCount: asked.count,
                    topicCount: topics.count
                )
            } catch let error as AppError {
                failures.append(error.userMessage)
                continue
            }
        }

        let detail = failures.last ?? "No topic had enough verified support."
        throw AppError.questionRejected(detail)
    }

    // MARK: Answering and evaluation

    public func submitAnswer(
        questionId: QuestionID,
        text: String,
        inputMode: AnswerInputMode,
        rawTranscript: String? = nil
    ) async throws -> AnswerFeedback {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.validationFailed("Write or dictate an answer before submitting.")
        }
        guard trimmed.count <= 8_000 else {
            throw AppError.validationFailed("The answer is too long.")
        }
        guard let question = try await repository.question(id: questionId) else {
            throw AppError.invalidStateTransition("The question no longer exists.")
        }
        guard let session = try await repository.session(id: question.sessionId), session.isActive else {
            throw AppError.invalidStateTransition("The session is not active.")
        }

        let attempt = AnswerAttempt(
            questionId: questionId,
            text: trimmed,
            inputMode: inputMode,
            rawTranscript: rawTranscript
        )
        try await repository.saveAttempt(attempt)

        do {
            let evaluation = try await evaluate(question: question, attempt: attempt, session: session)
            var updatedAttempt = attempt
            updatedAttempt.evaluationId = evaluation.id
            try await repository.updateAttempt(updatedAttempt)
            try await repository.deleteDraft(questionId: questionId)
            return try await feedback(question: question, attempt: updatedAttempt, evaluation: evaluation, snapshotId: session.snapshotId)
        } catch {
            // No verdict means no history entry: the draft stays available to retry.
            try? await repository.deleteAttempt(id: attempt.id)
            throw error
        }
    }

    /// Re-grades an existing attempt (after a crash or an unvalidatable verdict).
    public func retryEvaluation(attemptId: AttemptID, questionId: QuestionID) async throws -> AnswerFeedback {
        guard let question = try await repository.question(id: questionId) else {
            throw AppError.invalidStateTransition("The question no longer exists.")
        }
        guard let session = try await repository.session(id: question.sessionId), session.isActive else {
            throw AppError.invalidStateTransition("The session is not active.")
        }
        let attempts = try await repository.attempts(questionId: questionId)
        guard let attempt = attempts.first(where: { $0.id == attemptId }) else {
            throw AppError.invalidStateTransition("The answer attempt no longer exists.")
        }
        let evaluation = try await evaluate(question: question, attempt: attempt, session: session)
        var updatedAttempt = attempt
        updatedAttempt.evaluationId = evaluation.id
        try await repository.updateAttempt(updatedAttempt)
        try await repository.deleteDraft(questionId: questionId)
        return try await feedback(question: question, attempt: updatedAttempt, evaluation: evaluation, snapshotId: session.snapshotId)
    }

    public func overrideEvaluation(
        evaluationId: EvaluationID,
        status: EvaluationStatus,
        note: String? = nil
    ) async throws -> Evaluation {
        guard var evaluation = try await repository.evaluation(id: evaluationId) else {
            throw AppError.invalidStateTransition("The assessment no longer exists.")
        }
        evaluation.userOverride = EvaluationOverride(status: status, note: note, overriddenAt: Date())
        try await repository.updateEvaluation(evaluation)
        return evaluation
    }

    // MARK: Hints and solutions

    public func requestHint(questionId: QuestionID, level: Int) async throws -> Hint {
        guard (1...2).contains(level) else {
            throw AppError.validationFailed("Hints are available at level 1 or 2.")
        }
        guard let question = try await repository.question(id: questionId) else {
            throw AppError.invalidStateTransition("The question no longer exists.")
        }
        guard let session = try await repository.session(id: question.sessionId), session.isActive else {
            throw AppError.invalidStateTransition("The session is not active.")
        }
        let evidence = try await evidenceForQuestion(question, session: session)
        let provider = try await provider(for: session)
        let agentInstructions = try await agentPrompt(for: session)
        var request = PromptBuilder.hintRequest(
            agentInstructions: agentInstructions,
            question: question,
            level: level,
            evidence: Array(evidence.prefix(configuration.maximumEvidenceChunks)),
            configuration: configuration
        )
        request.conversationID = session.id.rawValue
        let completion = try await provider.complete(request)
        guard let data = JSONExtraction.objectData(from: completion.text) else {
            throw AppError.validationFailed("The hint response was not a JSON object.")
        }
        let validated = try HintValidator.validate(
            payloadData: data,
            question: question,
            authorizedEvidence: evidence,
            requestedLevel: level
        )
        let hintEvidence = evidence.filter { validated.evidenceChunkIds.contains($0.id) }
        return Hint(level: validated.level, text: validated.text, evidence: hintEvidence.isEmpty ? evidence : hintEvidence)
    }

    /// The answer as stated by the document. Available after an attempt, or on
    /// explicit request. Uses stored data only — no model call.
    public func solution(questionId: QuestionID) async throws -> Solution {
        guard let question = try await repository.question(id: questionId) else {
            throw AppError.invalidStateTransition("The question no longer exists.")
        }
        guard let session = try await repository.session(id: question.sessionId) else {
            throw AppError.invalidStateTransition("The session no longer exists.")
        }
        let evidence = try await evidenceForQuestion(question, session: session)
        return Solution(expectedPoints: question.rubric.expectedPoints, evidence: evidence)
    }

    // MARK: Progress

    public func topicPerformances(snapshotId: SnapshotID, scope: StudyScope? = nil) async throws -> [TopicPerformance] {
        let topics = try await repository.topics(snapshotId: snapshotId)
        let allowed = scope.map { Set($0.matchedChunkIds) }
        let filteredTopics = topics.compactMap { topic -> Topic? in
            guard let allowed else { return topic }
            let ids = topic.sourceChunkIds.filter { allowed.contains($0) }
            guard !ids.isEmpty else { return nil }
            var copy = topic
            copy.sourceChunkIds = ids
            return copy
        }
        let attempts = try await repository.topicAttempts(snapshotId: snapshotId)
        let grouped = Dictionary(grouping: attempts, by: \.topicId)
        return filteredTopics.map { topic in
            ReviewScoring.performance(for: topic, attempts: grouped[topic.id] ?? [])
        }
    }

    public func weakTopics(snapshotId: SnapshotID, scope: StudyScope? = nil) async throws -> [TopicPerformance] {
        let performances = try await topicPerformances(snapshotId: snapshotId, scope: scope)
        return performances
            .filter { $0.mastery == .weak || $0.mastery == .needsReinforcement }
            .sorted(by: ReviewScoring.reviewPriority)
    }

    // MARK: Scopes

    public func resolveScope(query: String, snapshotId: SnapshotID) async throws -> ScopeResolution {
        try await scopeResolver.resolve(query: query, snapshotId: snapshotId)
    }

    public func scopeSuggestions(snapshotId: SnapshotID, limit: Int = 8) async throws -> [ScopeSuggestion] {
        try await scopeResolver.suggestions(snapshotId: snapshotId, limit: limit)
    }

    public func confirmScope(
        query: String,
        snapshotId: SnapshotID,
        chunkIds: [ChunkID]?,
        title: String? = nil
    ) async throws -> StudyScope {
        try await scopeResolver.makeScope(
            query: query,
            snapshotId: snapshotId,
            chunkIds: chunkIds,
            title: title,
            confirmedByUser: true
        )
    }

    public func fullDocumentScope(snapshotId: SnapshotID) async throws -> StudyScope {
        try await scopeResolver.fullDocumentScope(snapshotId: snapshotId)
    }

    public func scope(id: ScopeID) async throws -> StudyScope? {
        try await repository.scope(id: id)
    }

    /// Changes the focus for subsequent questions. Existing questions, rubrics
    /// and assessments keep the scope they were created in.
    public func changeSessionScope(sessionId: SessionID, scopeId: ScopeID) async throws -> StudySession {
        guard var session = try await repository.session(id: sessionId), session.isActive else {
            throw AppError.invalidStateTransition("The session is not active.")
        }
        guard let scope = try await repository.scope(id: scopeId), scope.snapshotId == session.snapshotId else {
            throw AppError.invalidStateTransition("The selected focus does not belong to this document version.")
        }
        session.currentScopeId = scope.id
        try await repository.updateSession(session)
        return session
    }

    // MARK: Internals

    private func evaluate(question: Question, attempt: AnswerAttempt, session: StudySession) async throws -> Evaluation {
        let evidence = try await evidenceForQuestion(question, session: session)
        let provider = try await provider(for: session)
        let agentInstructions = try await agentPrompt(for: session)
        let topic = try await repository.topic(id: question.topicId)

        var request = PromptBuilder.evaluationRequest(
            agentInstructions: agentInstructions,
            question: question,
            topicTitle: topic?.title,
            studentAnswer: attempt.text,
            evidence: evidence,
            configuration: configuration
        )
        request.conversationID = session.id.rawValue

        do {
            let completion = try await provider.complete(request)
            guard let data = JSONExtraction.objectData(from: completion.text) else {
                throw AppError.evaluationRejected("The assessment was not a JSON object.")
            }
            let validated = try EvaluationValidator.validate(
                payloadData: data,
                question: question,
                authorizedEvidence: evidence
            )
            let evaluation = Evaluation(
                attemptId: attempt.id,
                status: validated.status,
                feedback: validated.feedback,
                correctPointIds: validated.correctPointIds,
                missingPointIds: validated.missingPointIds,
                incorrectStatements: validated.incorrectStatements,
                evidenceChunkIds: validated.evidenceChunkIds,
                providerProfileId: completion.providerProfileId,
                modelId: completion.modelId,
                promptVersionId: session.promptVersionId,
                notEvaluableReason: nil
            )
            try await repository.saveEvaluation(evaluation)
            return evaluation
        } catch let error as AppError {
            switch error {
            case .evaluationRejected, .validationFailed, .insufficientEvidence:
                let evaluation = Evaluation(
                    attemptId: attempt.id,
                    status: .notEvaluable,
                    feedback: "This answer could not be graded reliably against the document. Try again, or ask for the answer from the document.",
                    evidenceChunkIds: question.rubric.sourceChunkIds,
                    providerProfileId: provider.profile.id,
                    modelId: provider.profile.modelId,
                    promptVersionId: session.promptVersionId,
                    notEvaluableReason: error.userMessage
                )
                try await repository.saveEvaluation(evaluation)
                return evaluation
            default:
                throw error
            }
        }
    }

    private func feedback(
        question: Question,
        attempt: AnswerAttempt,
        evaluation: Evaluation,
        snapshotId: SnapshotID
    ) async throws -> AnswerFeedback {
        let evidence = try await retriever.evidence(forChunkIds: evaluation.evidenceChunkIds, in: snapshotId)
        let fallbackEvidence = evidence.isEmpty
            ? try await retriever.evidence(forChunkIds: question.rubric.sourceChunkIds, in: snapshotId)
            : evidence
        let topic = try await repository.topic(id: question.topicId)
        return AnswerFeedback(
            question: question,
            topic: topic,
            attempt: attempt,
            evaluation: evaluation,
            evidence: fallbackEvidence
        )
    }

    private func provider(for session: StudySession) async throws -> any LLMProvider {
        if let cached = providerCache[session.id] { return cached }
        let provider = try await providerResolver(session.modelProfileId)
        providerCache[session.id] = provider
        return provider
    }

    private func agentPrompt(for session: StudySession) async throws -> String {
        if let cached = promptCache[session.promptVersionId] { return cached }
        if let version = try await prompts.version(id: session.promptVersionId) {
            promptCache[session.promptVersionId] = version.content
            return version.content
        }
        // The exact version used by this session must exist; fall back to the
        // active one only if the database lost it, and say so in the session log.
        let active = try await prompts.activeVersion()
        promptCache[active.id] = active.content
        return active.content
    }

    private func ensureTopics(snapshot: DocumentSnapshot) async throws -> [Topic] {
        try await TopicCatalogBuilder.ensureTopics(repository: repository, snapshotId: snapshot.id)
    }

    private func currentScope(for session: StudySession) async throws -> StudyScope? {
        guard let id = session.currentScopeId else { return nil }
        return try await repository.scope(id: id)
    }

    /// Topics restricted to the scope's allowlist. Topics that do not intersect
    /// the focus are never offered, so questions cannot drift outside it.
    private func scopedTopics(session: StudySession, scope: StudyScope?) async throws -> [Topic] {
        let topics = try await ensureTopics(snapshot: try await snapshotRequired(for: session))
        guard let scope else { return topics }
        let allowed = Set(scope.matchedChunkIds)
        return topics.compactMap { topic in
            let ids = topic.sourceChunkIds.filter { allowed.contains($0) }
            guard !ids.isEmpty else { return nil }
            var copy = topic
            copy.sourceChunkIds = ids
            return copy
        }
    }

    private func snapshotRequired(for session: StudySession) async throws -> DocumentSnapshot {
        guard let snapshot = try await repository.snapshot(id: session.snapshotId) else {
            throw AppError.documentNoActiveSnapshot
        }
        return snapshot
    }

    private func questionScope(_ question: Question, session: StudySession) async throws -> StudyScope? {
        if let scopeId = question.scopeId {
            return try await repository.scope(id: scopeId)
        }
        return try await currentScope(for: session)
    }

    /// Evidence for one question, checked against its frozen scope allowlist.
    private func evidenceForQuestion(_ question: Question, session: StudySession) async throws -> [SourceChunk] {
        let scope = try await questionScope(question, session: session)
        let evidence = try await retriever.evidence(forChunkIds: question.rubric.sourceChunkIds, in: session.snapshotId)
        guard !evidence.isEmpty else {
            throw AppError.insufficientEvidence("The question's source passages are no longer available.")
        }
        if let scope {
            let allowed = Set(scope.matchedChunkIds)
            guard evidence.allSatisfy({ allowed.contains($0.id) }) else {
                throw AppError.insufficientEvidence("This question cites passages outside the selected focus.")
            }
        }
        return evidence
    }

    private func selectTopic(
        topics: [Topic],
        askedCounts: [TopicID: Int],
        performances: [TopicPerformance],
        mode: SessionMode,
        excluding: Set<TopicID>
    ) -> Topic? {
        let candidates = topics.filter { !excluding.contains($0.id) }
        guard !candidates.isEmpty else { return nil }

        switch mode {
        case .fullStudy:
            return candidates.min { lhs, rhs in
                let lhsCount = askedCounts[lhs.id] ?? 0
                let rhsCount = askedCounts[rhs.id] ?? 0
                if lhsCount != rhsCount { return lhsCount < rhsCount }
                return lhs.order < rhs.order
            }
        case .review:
            let byId = Dictionary(uniqueKeysWithValues: performances.map { ($0.topic.id, $0) })
            return candidates.min { lhs, rhs in
                let lhsPerf = byId[lhs.id]
                let rhsPerf = byId[rhs.id]
                if let lhsPerf, let rhsPerf, lhsPerf.mastery != rhsPerf.mastery {
                    return ReviewScoring.reviewPriority(lhsPerf, rhsPerf)
                }
                if lhsPerf == nil, rhsPerf != nil { return false }
                if lhsPerf != nil, rhsPerf == nil { return true }
                if let lhsPerf, let rhsPerf, lhsPerf.score != rhsPerf.score {
                    return (lhsPerf.score ?? 1) < (rhsPerf.score ?? 1)
                }
                let lhsCount = askedCounts[lhs.id] ?? 0
                let rhsCount = askedCounts[rhs.id] ?? 0
                if lhsCount != rhsCount { return lhsCount < rhsCount }
                return lhs.order < rhs.order
            }
        }
    }
}
