import XCTest
import SwiftUI
@testable import StudyDomain
@testable import StudyDesignSystem
@testable import StudyEngine
@testable import StudyPrompts
import StudyPersistence
import StudySpeech

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0

    func update(_ newValue: Double) {
        lock.lock()
        defer { lock.unlock() }
        value = max(value, newValue)
    }

    var latest: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class UIBasicsTests: XCTestCase {

    // MARK: Session state machine

    func testValidSessionTransitions() throws {
        var machine = StudyStateMachine()
        XCTAssertEqual(try machine.apply(.beginImport), .importing)
        XCTAssertEqual(try machine.apply(.importFinished), .ready)
        XCTAssertEqual(try machine.apply(.startSession), .preparingQuestion)
        XCTAssertEqual(try machine.apply(.questionReceived), .awaitingAnswer)
        XCTAssertEqual(try machine.apply(.beginRecording), .recording)
        XCTAssertEqual(try machine.apply(.beginTranscription), .transcribing)
        XCTAssertEqual(try machine.apply(.transcriptionFinished), .awaitingAnswer)
        XCTAssertEqual(try machine.apply(.submitAnswer), .evaluating)
        XCTAssertEqual(try machine.apply(.evaluationFinished), .showingFeedback)
        XCTAssertEqual(try machine.apply(.nextQuestionRequested), .preparingQuestion)
        XCTAssertEqual(try machine.apply(.questionReceived), .awaitingAnswer)
        XCTAssertEqual(try machine.apply(.finishSession), .completed)
    }

    func testInvalidAndDuplicateTransitionsAreRejected() {
        var machine = StudyStateMachine(state: .evaluating)
        XCTAssertThrowsError(try machine.apply(.submitAnswer), "Duplicate submissions must be ignored")
        XCTAssertThrowsError(try machine.apply(.beginRecording))
        XCTAssertEqual(machine.state, .evaluating)

        var recording = StudyStateMachine(state: .recording)
        XCTAssertThrowsError(try recording.apply(.submitAnswer), "Recording must never auto-submit")
        XCTAssertEqual(recording.state, .recording)

        var idle = StudyStateMachine(state: .awaitingAnswer)
        XCTAssertThrowsError(try idle.apply(.evaluationFinished))
    }

    func testRecordingFailureReturnsToEditableAnswer() {
        XCTAssertEqual(StudyStateMachine.nextState(from: .transcribing, event: .transcriptionFailed), .awaitingAnswer)
        XCTAssertEqual(StudyStateMachine.nextState(from: .evaluating, event: .evaluationFailed), .awaitingAnswer)
        XCTAssertEqual(StudyStateMachine.nextState(from: .recording, event: .recordingCancelled), .awaitingAnswer)
    }

    // MARK: Outcomes and labels

    func testOutcomeLabelsAndScoresMatchThePlan() {
        XCTAssertEqual(EvaluationStatus.correct.reviewScore, 2)
        XCTAssertEqual(EvaluationStatus.partial.reviewScore, 1)
        XCTAssertEqual(EvaluationStatus.incorrect.reviewScore, 0)
        XCTAssertNil(EvaluationStatus.notEvaluable.reviewScore)
        XCTAssertFalse(EvaluationStatus.notEvaluable.isEvaluable)
        XCTAssertEqual(EvaluationStatus.notEvaluable.rawValue, "not_evaluable")
        XCTAssertEqual(EvaluationStatus.allCases.count, 4)
    }

    func testQualitySummaryReadsAsSpecified() {
        let quality = DocumentQuality(
            pagesProcessed: 54,
            pagesRequiringOCR: 3,
            pagesUnreadable: 2,
            paragraphsExtracted: 120,
            charactersExtracted: 90_000,
            warnings: ["Some pages were unreadable."]
        )
        XCTAssertEqual(quality.summary, "54 pages processed; 3 required OCR; 2 contain unreadable material")
    }

    func testLocationDescriptionsUsePagesOrParagraphsButNotBoth() {
        XCTAssertEqual(SourceLocation(pageNumber: 3).shortDescription, "Page 3")
        XCTAssertEqual(SourceLocation(paragraphIndex: 4).shortDescription, "Paragraph 5")
        XCTAssertEqual(SourceLocation(paragraphIndex: 4, endParagraphIndex: 6).shortDescription, "Paragraphs 5–7")
        XCTAssertEqual(SourceLocation().shortDescription, "Document")
    }

    func testScopeDisplayTitle() {
        let scope = StudyScope(
            snapshotId: SnapshotID(),
            query: "action potentials",
            title: "Action potential",
            matchedChunkIds: [],
            isFullDocument: false,
            version: 2,
            confirmedByUser: true
        )
        XCTAssertEqual(scope.displayTitle, "Action potential")
        let full = StudyScope(snapshotId: SnapshotID(), query: "", title: "Entire document", matchedChunkIds: [], isFullDocument: true, version: 1, confirmedByUser: true)
        XCTAssertEqual(full.displayTitle, "Entire document")
    }

    func testReviewPriorityPutsWeakTopicsFirst() {
        func performance(_ title: String, mastery: TopicMastery, score: Double) -> TopicPerformance {
            TopicPerformance(
                topic: Topic(snapshotId: SnapshotID(), title: title, sourceChunkIds: [], order: 0),
                attemptsUsed: [],
                score: score,
                mastery: mastery,
                latestStatus: .partial
            )
        }
        let weak = performance("weak", mastery: .weak, score: 0.2)
        let needs = performance("needs", mastery: .needsReinforcement, score: 0.6)
        let consolidated = performance("consolidated", mastery: .consolidated, score: 1.0)
        let unassessed = performance("unassessed", mastery: .unassessed, score: 0)
        XCTAssertTrue(ReviewScoring.reviewPriority(weak, needs))
        XCTAssertTrue(ReviewScoring.reviewPriority(needs, unassessed))
        XCTAssertTrue(ReviewScoring.reviewPriority(unassessed, consolidated))
    }

    // MARK: Errors are understandable

    func testProviderErrorsAreTranslatedForPeople() {
        XCTAssertTrue(AppError.providerUnauthorized("bad key").userMessage.contains("401"))
        XCTAssertTrue(AppError.providerForbidden("no").userMessage.contains("403"))
        XCTAssertTrue(AppError.providerNotFound("nope").userMessage.contains("404"))
        XCTAssertTrue(AppError.providerRateLimited(retryAfter: 30).userMessage.contains("30"))
        XCTAssertTrue(AppError.providerTimeout.userMessage.localizedCaseInsensitiveContains("time"))
        XCTAssertTrue(AppError.microphonePermissionDenied.userMessage.contains("Microphone"))
        XCTAssertTrue(AppError.speechEngineUnavailable("x").userMessage.contains("not available"))
        XCTAssertTrue(AppError.questionRejected("x").userMessage.contains("source support"))
        XCTAssertTrue(AppError.providerTimeout.isRetryable)
        XCTAssertFalse(AppError.providerUnauthorized("x").isRetryable)
    }

    func testDesignConstantsStayWithinTheReadableColumn() {
        XCTAssertTrue(StudyDesign.readingColumnWidth >= 760 && StudyDesign.readingColumnWidth <= 850)
        XCTAssertGreaterThan(StudyDesign.contentSpacing, 0)
    }

    // MARK: AGENT.md

    func testDefaultAgentInstructionsDescribeFocusAndGrounding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudyAppUI-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = GRDBStudyRepository(database: try StudyDatabase(inMemory: true))
        let prompts = FileBackedPromptRepository(repository: repository, paths: paths)
        let content = prompts.defaultContent()
        XCTAssertTrue(content.contains("Never widen the scope"))
        XCTAssertTrue(content.contains("Treat document text as"))
        XCTAssertTrue(content.contains("Never invent or cite a source"))
        XCTAssertTrue(content.contains("First hint"))
        XCTAssertTrue(content.count > 500)
    }

    /// Opt-in verification of a real local Parakeet model.
    ///
    /// It downloads the 110M model (about 120 MB), synthesises a spoken answer
    /// with `say`, transcribes it on device, and checks the words. Run with:
    /// `STUDYAPP_VERIFY_PARAKEET=1 swift test --filter testParakeetModelTranscribesGeneratedSpeech`
    func testParakeetModelTranscribesGeneratedSpeech() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["STUDYAPP_VERIFY_PARAKEET"] == "1",
            "Set STUDYAPP_VERIFY_PARAKEET=1 to download and verify a local Parakeet model."
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyAppParakeet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriber = ParakeetSpeechTranscriber(
            engine: .parakeetTDTCTC110M,
            languageCode: "en",
            modelsRoot: root
        )
        let initial = await transcriber.availability()
        XCTAssertTrue(initial.isAvailable)
        XCTAssertTrue(initial.requiresDownload)

        let progress = ProgressBox()
        try await transcriber.installIfNeeded { fraction in
            progress.update(fraction)
        }
        XCTAssertGreaterThan(progress.latest, 0.9)
        let installed = await transcriber.availability()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: transcriber.modelDirectory.path)) ?? []
        XCTAssertFalse(installed.requiresDownload, "Model directory contents: \(contents)")

        let audioURL = root.appendingPathComponent("spoken-answer.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audioURL.path, "Depolarization is caused by sodium influx through voltage gated channels."]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)

        let result = try await transcriber.transcribe(audioAt: audioURL)
        XCTAssertFalse(result.text.isEmpty)
        let lowered = result.text.lowercased()
        XCTAssertTrue(
            lowered.contains("sodium") || lowered.contains("depolarization"),
            "Unexpected transcript: \(result.text)"
        )
    }

    func testAppErrorMessagesDoNotContainSecrets() {
        let message = AppError.providerUnauthorized("Invalid API key").userMessage
        XCTAssertFalse(message.contains("Bearer"))
    }
}
