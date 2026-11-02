import Foundation
import SwiftUI
import StudyDomain
import StudyPersistence
import StudyEngine
import StudySpeech

@MainActor
final class StudyViewModel: ObservableObject {
    let session: StudySession
    let document: StudyDocument
    let recorder = AudioRecorder()

    @Published var state: StudyState = .empty
    @Published var overview: SessionOverview
    @Published var prepared: PreparedQuestion?
    @Published var draft: String = ""
    @Published var feedback: AnswerFeedback?
    @Published var hint: Hint?
    @Published var solution: Solution?
    @Published var errorMessage: String?
    @Published var errorIsRetryable: Bool = false
    @Published var busyPhase: String?
    @Published var transcriptionPhase: String?
    @Published var rawTranscript: String?
    @Published var inputMode: AnswerInputMode = .typed
    @Published var summary: SessionSummary?
    @Published var sourceViewerTarget: SourceViewerTarget?
    @Published var sessionFinished: Bool = false
    @Published var currentScope: StudyScope?

    private let engine: StudyEngine
    private let repository: GRDBStudyRepository
    private let speechManager: SpeechModelManager
    private let paths: AppPaths
    private var speechProfile: SpeechProfile?
    private var machine = StudyStateMachine()
    private var tasks: [Task<Void, Never>] = []
    private var draftSaveTask: Task<Void, Never>?
    private var lastAttemptId: AttemptID?

    struct SourceViewerTarget: Identifiable, Equatable {
        var id: String { chunkIds.map(\.rawValue).joined(separator: ",") + (page.map(String.init) ?? "") }
        var chunkIds: [ChunkID]
        var page: Int?
        var title: String
    }

    init(
        engine: StudyEngine,
        repository: GRDBStudyRepository,
        speechManager: SpeechModelManager,
        session: StudySession,
        document: StudyDocument,
        paths: AppPaths,
        speechProfile: SpeechProfile?
    ) {
        self.engine = engine
        self.repository = repository
        self.speechManager = speechManager
        self.session = session
        self.document = document
        self.paths = paths
        self.speechProfile = speechProfile
        self.overview = SessionOverview(answeredCount: 0, topicCount: 0, statusCounts: [:])
        self.state = .preparingQuestion
    }

    func updateSpeechProfile(_ profile: SpeechProfile?) {
        speechProfile = profile
    }

    // MARK: Loading and resuming

    func load() async {
        do {
            let snapshot = try await engine.sessionSnapshot(sessionId: session.id)
            overview = snapshot.overview
            currentScope = snapshot.currentScope
            if snapshot.session.state == .completed {
                sessionFinished = true
            }
            if let question = snapshot.question, let evaluation = snapshot.evaluation, let attempt = snapshot.attempt {
                prepared = PreparedQuestion(
                    question: question,
                    topic: snapshot.topic ?? Topic(snapshotId: session.snapshotId, title: "Document", sourceChunkIds: question.rubric.sourceChunkIds, order: 0),
                    evidence: snapshot.evidence,
                    topicPerformance: nil,
                    answeredCount: snapshot.overview.answeredCount,
                    topicCount: snapshot.overview.topicCount
                )
                feedback = AnswerFeedback(
                    question: question,
                    topic: snapshot.topic,
                    attempt: attempt,
                    evaluation: evaluation,
                    evidence: snapshot.evidence
                )
                lastAttemptId = attempt.id
                draft = ""
                transition(.evaluationFinished, to: .showingFeedback)
            } else if let question = snapshot.question {
                prepared = PreparedQuestion(
                    question: question,
                    topic: snapshot.topic ?? Topic(snapshotId: session.snapshotId, title: "Document", sourceChunkIds: question.rubric.sourceChunkIds, order: 0),
                    evidence: snapshot.evidence,
                    topicPerformance: nil,
                    answeredCount: snapshot.overview.answeredCount,
                    topicCount: snapshot.overview.topicCount
                )
                draft = snapshot.draft
                inputMode = .typed
                transition(.questionReceived, to: .awaitingAnswer)
            } else {
                await askNextQuestion()
            }
        } catch {
            setError(error, retryable: true)
            state = .failed
        }
    }

    func cancelWork() async {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        draftSaveTask?.cancel()
        draftSaveTask = nil
        if recorder.isRecording {
            recorder.cancel()
        }
        await saveDraftNow()
    }

    // MARK: Question lifecycle

    func askNextQuestion() async {
        guard !sessionFinished else { return }
        hint = nil
        solution = nil
        feedback = nil
        errorMessage = nil
        setState(.preparingQuestion)
        busyPhase = "Preparing a question from the document"
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await self.engine.nextQuestion(sessionId: self.session.id)
                guard !Task.isCancelled else { return }
                self.prepared = prepared
                self.draft = ""
                self.inputMode = .typed
                self.rawTranscript = nil
                self.overview = (try? await self.engine.overview(sessionId: self.session.id)) ?? self.overview
                self.busyPhase = nil
                self.setState(.awaitingAnswer)
            } catch is CancellationError {
                self.busyPhase = nil
            } catch {
                self.busyPhase = nil
                self.setError(error, retryable: true)
                self.setState(.failed)
            }
        }
        tasks.append(task)
        await task.value
    }

    func submitAnswer() async {
        guard state == .awaitingAnswer, let prepared else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            setError(AppError.validationFailed("Write or dictate an answer before submitting."), retryable: false)
            return
        }
        cancelDraftSave()
        errorMessage = nil
        setState(.evaluating)
        busyPhase = "Checking your answer against the document"
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.engine.submitAnswer(
                    questionId: prepared.question.id,
                    text: text,
                    inputMode: self.inputMode,
                    rawTranscript: self.rawTranscript
                )
                guard !Task.isCancelled else { return }
                self.feedback = result
                self.lastAttemptId = result.attempt.id
                self.draft = ""
                self.busyPhase = nil
                self.overview = (try? await self.engine.overview(sessionId: self.session.id)) ?? self.overview
                self.setState(.showingFeedback)
            } catch is CancellationError {
                self.busyPhase = nil
            } catch {
                self.busyPhase = nil
                self.setError(error, retryable: (error as? AppError)?.isRetryable ?? true)
                self.setState(.awaitingAnswer)
            }
        }
        tasks.append(task)
        await task.value
    }

    func retryEvaluation() async {
        guard let question = prepared?.question else { return }
        guard let attemptId = lastAttemptId ?? feedback?.attempt.id else {
            await submitAnswer()
            return
        }
        errorMessage = nil
        setState(.evaluating)
        busyPhase = "Grading the answer again"
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.engine.retryEvaluation(attemptId: attemptId, questionId: question.id)
                guard !Task.isCancelled else { return }
                self.feedback = result
                self.lastAttemptId = result.attempt.id
                self.busyPhase = nil
                self.setState(.showingFeedback)
            } catch {
                self.busyPhase = nil
                self.setError(error, retryable: true)
                self.setState(self.feedback == nil ? .awaitingAnswer : .showingFeedback)
            }
        }
        tasks.append(task)
        await task.value
    }

    func tryAgain() {
        guard let feedback else { return }
        self.feedback = nil
        self.hint = nil
        self.solution = nil
        self.draft = feedback.attempt.text
        self.inputMode = feedback.attempt.inputMode
        self.rawTranscript = feedback.attempt.rawTranscript
        self.errorMessage = nil
        setState(.awaitingAnswer)
    }

    func requestHint(level: Int) async {
        guard let prepared else { return }
        guard hint == nil || hint?.level != level else { return }
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                self.hint = try await self.engine.requestHint(questionId: prepared.question.id, level: level)
            } catch {
                self.setError(error, retryable: true)
            }
        }
        tasks.append(task)
        await task.value
    }

    func showSolution() async {
        guard let prepared else { return }
        errorMessage = nil
        do {
            solution = try await engine.solution(questionId: prepared.question.id)
        } catch {
            setError(error, retryable: false)
        }
    }

    // MARK: Focus

    /// Changes the focus for later questions. Existing questions, answers and
    /// assessments stay attached to the scope they were asked in.
    func changeScope(_ scope: StudyScope) async {
        await cancelWork()
        do {
            _ = try await engine.changeSessionScope(sessionId: session.id, scopeId: scope.id)
            currentScope = scope
            overview = (try? await engine.overview(sessionId: session.id)) ?? overview
            errorMessage = nil
            hint = nil
            solution = nil
            if state == .showingFeedback || state == .completed {
                // Keep the previous feedback visible; the next question uses the new focus.
                return
            }
            prepared = nil
            feedback = nil
            draft = ""
            await askNextQuestion()
        } catch {
            setError(error, retryable: false)
        }
    }

    func changeToEntireDocument() async {
        do {
            let scope = try await engine.fullDocumentScope(snapshotId: session.snapshotId)
            await changeScope(scope)
        } catch {
            setError(error, retryable: false)
        }
    }

    var focusLabel: String {
        currentScope?.displayTitle ?? "Entire document"
    }

    func finishSession() async {
        await saveDraftNow()
        do {
            summary = try await engine.finishSession(sessionId: session.id)
            sessionFinished = true
            setState(.completed)
            feedback = nil
        } catch {
            setError(error, retryable: false)
        }
    }

    // MARK: Recording

    func startRecording() async {
        guard state == .awaitingAnswer else { return }
        guard let profile = speechProfile else {
            setError(AppError.speechEngineUnavailable("Choose a speech engine in Settings first."), retryable: false)
            return
        }
        errorMessage = nil
        let availability = await speechManager.availability(for: profile)
        guard availability.isAvailable else {
            setError(AppError.speechEngineUnavailable(availability.detail), retryable: false)
            return
        }
        guard !availability.requiresDownload else {
            setError(AppError.speechModelNotInstalled("Download \(profile.engine.displayName) in Settings first."), retryable: false)
            return
        }
        do {
            try await recorder.start(in: paths.audioTemporaryDirectory)
            setState(.recording)
        } catch {
            setError(error, retryable: false)
        }
    }

    func stopRecordingAndTranscribe() async {
        guard state == .recording else { return }
        guard let audioURL = recorder.stop() else {
            setState(.awaitingAnswer)
            setError(AppError.speechNoAudio, retryable: false)
            return
        }
        guard let profile = speechProfile else {
            try? FileManager.default.removeItem(at: audioURL)
            setState(.awaitingAnswer)
            setError(AppError.speechEngineUnavailable("Choose a speech engine in Settings first."), retryable: false)
            return
        }
        setState(.transcribing)
        transcriptionPhase = "Transcribing on this Mac"
        defer { transcriptionPhase = nil }
        do {
            let result = try await speechManager.transcribe(profile: profile, audioAt: audioURL)
            rawTranscript = result.text
            inputMode = .speech
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = result.text
            } else {
                draft += (draft.hasSuffix(" ") ? "" : " ") + result.text
            }
            setState(.awaitingAnswer)
        } catch {
            setState(.awaitingAnswer)
            setError(error, retryable: (error as? AppError)?.isRetryable ?? false)
        }
        try? FileManager.default.removeItem(at: audioURL)
    }

    func cancelRecording() {
        guard state == .recording else { return }
        recorder.cancel()
        setState(.awaitingAnswer)
    }

    // MARK: Drafts

    func draftChanged(_ text: String) {
        draft = text
        guard let question = prepared?.question, state == .awaitingAnswer else { return }
        cancelDraftSave()
        let engine = self.engine
        draftSaveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            try? await engine.saveDraft(questionId: question.id, text: text)
        }
    }

    func saveDraftNow() async {
        guard let question = prepared?.question, state == .awaitingAnswer else { return }
        try? await engine.saveDraft(questionId: question.id, text: draft)
    }

    private func cancelDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
    }

    // MARK: Source viewer

    func openSource() {
        guard let prepared else { return }
        let page = prepared.evidence.compactMap(\.location.pageNumber).min()
        sourceViewerTarget = SourceViewerTarget(
            chunkIds: prepared.evidence.map(\.id),
            page: page,
            title: prepared.topic.title
        )
    }

    func openSource(for feedback: AnswerFeedback) {
        let page = feedback.evidence.compactMap(\.location.pageNumber).min()
        sourceViewerTarget = SourceViewerTarget(
            chunkIds: feedback.evidence.map(\.id),
            page: page,
            title: feedback.topic?.title ?? "Source"
        )
    }

    // MARK: State helpers

    private func transition(_ event: StudyEvent, to newState: StudyState) {
        _ = try? machine.apply(event)
        state = newState
    }

    private func setState(_ newState: StudyState) {
        machine = StudyStateMachine(state: newState)
        state = newState
    }

    private func setError(_ error: Error, retryable: Bool) {
        if error is CancellationError { return }
        let message: String
        if let appError = error as? AppError {
            message = appError.userMessage
            errorIsRetryable = retryable && appError.isRetryable
        } else {
            message = error.localizedDescription
            errorIsRetryable = retryable
        }
        errorMessage = message
    }

    func clearError() {
        errorMessage = nil
    }

    func overrideEvaluation(status: EvaluationStatus) async {
        guard let evaluation = feedback?.evaluation else { return }
        do {
            let updated = try await engine.overrideEvaluation(evaluationId: evaluation.id, status: status)
            if var feedback {
                feedback.evaluation = updated
                self.feedback = feedback
            }
        } catch {
            setError(error, retryable: false)
        }
    }

    var progressFraction: Double? {
        guard overview.topicCount > 0 else { return nil }
        return min(1, Double(overview.answeredCount) / Double(overview.topicCount))
    }

    var canSubmit: Bool {
        state == .awaitingAnswer && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
