import XCTest
import Foundation
@testable import StudyPersistence
import StudyPrompts
import StudyDomain

final class PersistenceTests: XCTestCase {
    var paths: AppPaths!
    var database: StudyDatabase!
    var repository: GRDBStudyRepository!

    override func setUpWithError() throws {
        paths = AppPaths(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("StudyAppPersistence-\(UUID().uuidString)", isDirectory: true)
        )
        try paths.createDirectories()
        database = try StudyDatabase(paths: paths)
        repository = GRDBStudyRepository(database: database)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: paths.root)
    }

    private func makeImport(name: String = "Neurophysiology") async throws -> (StudyDocument, DocumentSnapshot, [SourceChunk]) {
        let documentId = DocumentID()
        let snapshotId = SnapshotID()
        let section = DocumentSection(snapshotId: snapshotId, title: "Action potential", level: 1, order: 0, location: SourceLocation(pageNumber: 1))
        let textA = "Depolarization is caused by sodium influx."
        let textB = "Repolarization is caused by potassium efflux."
        let chunkA = SourceChunk(snapshotId: snapshotId, text: textA, sectionId: section.id, location: SourceLocation(pageNumber: 1, paragraphIndex: 0), startOffset: 0, endOffset: textA.utf16.count, extractionMethod: .pdfText, quality: 1, isUsableAsEvidence: true, order: 0)
        let chunkB = SourceChunk(snapshotId: snapshotId, text: textB, sectionId: section.id, location: SourceLocation(pageNumber: 1, paragraphIndex: 1), startOffset: textA.utf16.count + 2, endOffset: textA.utf16.count + 2 + textB.utf16.count, extractionMethod: .pdfText, quality: 1, isUsableAsEvidence: true, order: 1)
        let fullText = textA + "\n\n" + textB
        let snapshot = DocumentSnapshot(
            id: snapshotId,
            documentId: documentId,
            version: 1,
            textHash: TextUtilities.sha256Hex(fullText),
            quality: DocumentQuality(pagesProcessed: 1, pagesRequiringOCR: 0, pagesUnreadable: 0, paragraphsExtracted: 2, charactersExtracted: fullText.count, warnings: [])
        )
        let document = StudyDocument(
            id: documentId,
            name: name,
            fileType: .pdf,
            storedFileName: "\(documentId.rawValue).pdf",
            sha256: "sha-\(documentId.rawValue)",
            state: .ready,
            language: "en",
            parserVersion: "test",
            activeSnapshotId: snapshotId
        )
        let result = DocumentImportResult(
            documentName: name,
            fileType: .pdf,
            fileHash: document.sha256,
            textHash: snapshot.textHash,
            storedFileName: document.storedFileName,
            snapshot: snapshot,
            sections: [section],
            chunks: [chunkA, chunkB],
            fullText: fullText,
            language: "en",
            parserVersion: "test"
        )
        try await repository.saveImport(result, document: document)
        return (document, snapshot, [chunkA, chunkB])
    }

    func testRoundTripKeepsProvenanceAndRubric() async throws {
        let (document, snapshot, chunks) = try await makeImport()
        let loadedDocument = try await repository.document(id: document.id)
        XCTAssertEqual(loadedDocument?.activeSnapshotId, snapshot.id)
        XCTAssertEqual(loadedDocument?.state, .ready)

        let loadedChunks = try await repository.chunks(snapshotId: snapshot.id)
        XCTAssertEqual(loadedChunks.count, 2)
        XCTAssertEqual(loadedChunks.first?.location.pageNumber, 1)
        XCTAssertEqual(loadedChunks.first?.startOffset, 0)

        let topic = Topic(snapshotId: snapshot.id, title: "Action potential", sourceChunkIds: chunks.map(\.id), order: 0)
        try await repository.saveTopics([topic])
        let topics = try await repository.topics(snapshotId: snapshot.id)
        XCTAssertEqual(topics.first?.sourceChunkIds, chunks.map(\.id))

        let scope = StudyScope(
            snapshotId: snapshot.id,
            query: "action potential",
            title: "Action potential",
            matchedChunkIds: chunks.map(\.id),
            isFullDocument: false,
            version: 1,
            confirmedByUser: true
        )
        try await repository.saveScope(scope)
        let loadedScope = try await repository.scope(id: scope.id)
        XCTAssertEqual(loadedScope?.id, scope.id)
        XCTAssertEqual(loadedScope?.query, scope.query)
        XCTAssertEqual(loadedScope?.title, scope.title)
        XCTAssertEqual(loadedScope?.matchedChunkIds, scope.matchedChunkIds)
        XCTAssertEqual(loadedScope?.isFullDocument, scope.isFullDocument)
        XCTAssertEqual(loadedScope?.version, scope.version)
        XCTAssertEqual(loadedScope?.confirmedByUser, scope.confirmedByUser)

        let prompt = try await FileBackedPromptRepository(repository: repository, paths: paths).activeVersion()
        let session = StudySession(
            documentId: document.id,
            snapshotId: snapshot.id,
            mode: .fullStudy,
            promptVersionId: prompt.id,
            scopeId: scope.id,
            currentScopeId: scope.id
        )
        try await repository.saveSession(session)

        let question = Question(
            sessionId: session.id,
            topicId: topic.id,
            text: "What causes depolarization and repolarization?",
            rubric: QuestionRubric(
                expectedPoints: [
                    ExpectedPoint(id: "p1", text: "Depolarization is caused by sodium influx.", sourceChunkIds: [chunks[0].id]),
                    ExpectedPoint(id: "p2", text: "Repolarization is caused by potassium efflux.", sourceChunkIds: [chunks[1].id]),
                ],
                sourceChunkIds: chunks.map(\.id),
                answerability: .supported
            ),
            normalizedTextHash: "hash",
            scopeId: scope.id
        )
        try await repository.saveQuestion(question)

        let loadedQuestion = try await repository.question(id: question.id)
        XCTAssertEqual(loadedQuestion?.rubric, question.rubric)
        XCTAssertEqual(loadedQuestion?.scopeId, scope.id)

        let loadedSession = try await repository.session(id: session.id)
        XCTAssertEqual(loadedSession?.scopeId, scope.id)
        XCTAssertEqual(loadedSession?.currentScopeId, scope.id)
        XCTAssertEqual(loadedSession?.promptVersionId, prompt.id)
    }

    func testReimportCreatesANewSnapshotAndHistoricalQuestionsKeepTheOldOne() async throws {
        let (document, oldSnapshot, oldChunks) = try await makeImport()
        let prompt = try await FileBackedPromptRepository(repository: repository, paths: paths).activeVersion()
        let scope = StudyScope(snapshotId: oldSnapshot.id, query: "action", title: "Action", matchedChunkIds: [oldChunks[0].id], isFullDocument: false, version: 1, confirmedByUser: true)
        try await repository.saveScope(scope)
        let session = StudySession(documentId: document.id, snapshotId: oldSnapshot.id, mode: .fullStudy, promptVersionId: prompt.id, scopeId: scope.id, currentScopeId: scope.id)
        try await repository.saveSession(session)
        let question = Question(
            sessionId: session.id,
            topicId: TopicID(),
            text: "What causes depolarization?",
            rubric: QuestionRubric(expectedPoints: [ExpectedPoint(id: "p1", text: "Sodium influx.", sourceChunkIds: [oldChunks[0].id])], sourceChunkIds: [oldChunks[0].id], answerability: .supported),
            normalizedTextHash: "h",
            scopeId: scope.id
        )
        try await repository.saveQuestion(question)

        // A changed file becomes version 2 of the same document.
        let newSnapshot = DocumentSnapshot(
            id: SnapshotID(),
            documentId: document.id,
            version: 2,
            textHash: "new-text-hash",
            quality: DocumentQuality(pagesProcessed: 1, paragraphsExtracted: 1, charactersExtracted: 60)
        )
        let newText = "Depolarization is caused by sodium influx and calcium release."
        let newChunk = SourceChunk(
            snapshotId: newSnapshot.id,
            text: newText,
            location: SourceLocation(pageNumber: 1),
            startOffset: 0,
            endOffset: newText.utf16.count,
            extractionMethod: .pdfText,
            quality: 1,
            isUsableAsEvidence: true,
            order: 0
        )
        var updatedDocument = document
        updatedDocument.activeSnapshotId = newSnapshot.id
        updatedDocument.sha256 = "new-file-hash"
        try await repository.saveImport(
            DocumentImportResult(
                documentName: document.name,
                fileType: .pdf,
                fileHash: updatedDocument.sha256,
                textHash: newSnapshot.textHash,
                storedFileName: document.storedFileName,
                snapshot: newSnapshot,
                sections: [],
                chunks: [newChunk],
                fullText: newText,
                language: "en",
                parserVersion: "test-v2"
            ),
            document: updatedDocument
        )

        let snapshots = try await repository.snapshots(documentId: document.id)
        XCTAssertEqual(snapshots.map(\.version), [1, 2])
        let active = try await repository.activeSnapshot(for: document.id)
        XCTAssertEqual(active?.id, newSnapshot.id)

        // The old question, its scope and its source text are untouched.
        let storedQuestion = try await repository.question(id: question.id)
        XCTAssertEqual(storedQuestion?.rubric.sourceChunkIds, [oldChunks[0].id])
        let oldChunk = try await repository.chunks(ids: [oldChunks[0].id])
        XCTAssertEqual(oldChunk.count, 1)
        let oldScope = try await repository.scope(id: scope.id)
        XCTAssertEqual(oldScope?.snapshotId, oldSnapshot.id)
        let newChunks = try await repository.chunks(snapshotId: newSnapshot.id)
        XCTAssertEqual(newChunks.map(\.text), [newText])
    }

    func testDraftsPersistAndClearOnSubmit() async throws {
        let (document, snapshot, chunks) = try await makeImport()
        let prompt = try await FileBackedPromptRepository(repository: repository, paths: paths).activeVersion()
        let scope = StudyScope(snapshotId: snapshot.id, query: "action", title: "Action", matchedChunkIds: chunks.map(\.id), isFullDocument: false, version: 1, confirmedByUser: true)
        try await repository.saveScope(scope)
        let session = StudySession(documentId: document.id, snapshotId: snapshot.id, mode: .fullStudy, promptVersionId: prompt.id, scopeId: scope.id, currentScopeId: scope.id)
        try await repository.saveSession(session)
        let question = Question(
            sessionId: session.id,
            topicId: TopicID(),
            text: "Question?",
            rubric: QuestionRubric(expectedPoints: [ExpectedPoint(id: "p1", text: "x", sourceChunkIds: [chunks[0].id])], sourceChunkIds: [chunks[0].id], answerability: .supported),
            normalizedTextHash: "h",
            scopeId: scope.id
        )
        try await repository.saveQuestion(question)

        try await repository.saveDraft(questionId: question.id, text: "half an answer")
        let draft = try await repository.draftText(questionId: question.id)
        XCTAssertEqual(draft, "half an answer")
        try await repository.deleteDraft(questionId: question.id)
        let clearedDraft = try await repository.draftText(questionId: question.id)
        XCTAssertNil(clearedDraft)
    }

    func testHistoryFiltersAndOverridePreserveOriginal() async throws {
        let (document, snapshot, chunks) = try await makeImport(name: "Document A")
        let other = try await makeImport(name: "Document B")
        let prompt = try await FileBackedPromptRepository(repository: repository, paths: paths).activeVersion()

        func record(into document: StudyDocument, chunk: SourceChunk, status: EvaluationStatus, daysAgo: Int) async throws {
            let scope = StudyScope(snapshotId: snapshot.id, query: "", title: "Entire document", matchedChunkIds: [chunk.id], isFullDocument: false, version: 1, confirmedByUser: true)
            try await repository.saveScope(scope)
            let session = StudySession(
                documentId: document.id,
                snapshotId: document.activeSnapshotId!,
                startedAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400),
                mode: .fullStudy,
                promptVersionId: prompt.id,
                scopeId: scope.id,
                currentScopeId: scope.id
            )
            try await repository.saveSession(session)
            let question = Question(
                sessionId: session.id,
                topicId: TopicID(),
                text: "Question \(status.rawValue)?",
                rubric: QuestionRubric(expectedPoints: [ExpectedPoint(id: "p1", text: "x", sourceChunkIds: [chunk.id])], sourceChunkIds: [chunk.id], answerability: .supported),
                normalizedTextHash: UUID().uuidString,
                scopeId: scope.id
            )
            try await repository.saveQuestion(question)
            let attempt = AnswerAttempt(questionId: question.id, text: "answer", inputMode: .typed, createdAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400))
            try await repository.saveAttempt(attempt)
            let evaluation = Evaluation(
                attemptId: attempt.id,
                status: status,
                feedback: "feedback",
                evidenceChunkIds: [chunk.id],
                createdAt: attempt.createdAt
            )
            try await repository.saveEvaluation(evaluation)
        }

        try await record(into: document, chunk: chunks[0], status: .correct, daysAgo: 1)
        try await record(into: document, chunk: chunks[1], status: .incorrect, daysAgo: 2)
        try await record(into: other.0, chunk: other.2[0], status: .partial, daysAgo: 3)

        let all = try await repository.history(filters: .all)
        XCTAssertEqual(all.count, 3)
        let onlyA = try await repository.history(filters: HistoryFilters(documentId: document.id))
        XCTAssertEqual(onlyA.count, 2)
        let incorrect = try await repository.history(filters: HistoryFilters(status: .incorrect))
        XCTAssertEqual(incorrect.count, 1)
        let recent = try await repository.history(filters: HistoryFilters(from: Date().addingTimeInterval(-1.5 * 86_400)))
        XCTAssertEqual(recent.count, 1)

        let incorrectHistory = try await repository.history(filters: HistoryFilters(status: .incorrect))
        let recordToOverride = try XCTUnwrap(incorrectHistory.first)
        var evaluation = try XCTUnwrap(recordToOverride.evaluation)
        evaluation.userOverride = EvaluationOverride(status: .correct, note: "I was right")
        try await repository.updateEvaluation(evaluation)

        let afterOverride = try await repository.history(filters: HistoryFilters(documentId: document.id, status: .correct))
        XCTAssertEqual(afterOverride.count, 2, "The override is what the student sees")
        let stored = try await repository.evaluation(id: evaluation.id)
        XCTAssertEqual(stored?.status, .incorrect, "The original verdict remains stored")

        // The scope travels with the history record.
        XCTAssertEqual(recordToOverride.scope?.snapshotId, snapshot.id)
    }

    func testSessionProgressUsesEffectiveStatus() async throws {
        let fixture = try await makeImport()
        let prompt = try await FileBackedPromptRepository(repository: repository, paths: paths).activeVersion()
        let scope = StudyScope(snapshotId: fixture.1.id, query: "", title: "Entire document", matchedChunkIds: fixture.2.map(\.id), isFullDocument: true, version: 1, confirmedByUser: true)
        try await repository.saveScope(scope)
        let session = StudySession(documentId: fixture.0.id, snapshotId: fixture.1.id, mode: .fullStudy, promptVersionId: prompt.id, scopeId: scope.id, currentScopeId: scope.id)
        try await repository.saveSession(session)
        let question = Question(
            sessionId: session.id,
            topicId: TopicID(),
            text: "Q?",
            rubric: QuestionRubric(expectedPoints: [ExpectedPoint(id: "p1", text: "x", sourceChunkIds: [fixture.2[0].id])], sourceChunkIds: [fixture.2[0].id], answerability: .supported),
            normalizedTextHash: "h",
            scopeId: scope.id
        )
        try await repository.saveQuestion(question)
        let attempt = AnswerAttempt(questionId: question.id, text: "a", inputMode: .typed)
        try await repository.saveAttempt(attempt)
        var evaluation = Evaluation(attemptId: attempt.id, status: .incorrect, feedback: "no", evidenceChunkIds: [fixture.2[0].id])
        try await repository.saveEvaluation(evaluation)
        evaluation.userOverride = EvaluationOverride(status: .partial)
        try await repository.updateEvaluation(evaluation)

        let progress = try await repository.sessionProgress(sessionId: session.id)
        XCTAssertEqual(progress?.answeredCount, 1)
        XCTAssertEqual(progress?.statusCounts[.partial], 1)
        XCTAssertNil(progress?.statusCounts[.incorrect])

        let topicAttempts = try await repository.topicAttempts(snapshotId: fixture.1.id)
        XCTAssertEqual(topicAttempts.first?.status, .partial)
    }

    func testDeletingDocumentRemovesScopesQuestionsAndHistory() async throws {
        let (document, snapshot, chunks) = try await makeImport()
        let prompt = try await FileBackedPromptRepository(repository: repository, paths: paths).activeVersion()
        let scope = StudyScope(snapshotId: snapshot.id, query: "action", title: "Action", matchedChunkIds: chunks.map(\.id), isFullDocument: false, version: 1, confirmedByUser: true)
        try await repository.saveScope(scope)
        let session = StudySession(documentId: document.id, snapshotId: snapshot.id, mode: .fullStudy, promptVersionId: prompt.id, scopeId: scope.id, currentScopeId: scope.id)
        try await repository.saveSession(session)
        let question = Question(
            sessionId: session.id,
            topicId: TopicID(),
            text: "Q?",
            rubric: QuestionRubric(expectedPoints: [ExpectedPoint(id: "p1", text: "x", sourceChunkIds: [chunks[0].id])], sourceChunkIds: [chunks[0].id], answerability: .supported),
            normalizedTextHash: "h",
            scopeId: scope.id
        )
        try await repository.saveQuestion(question)
        let attempt = AnswerAttempt(questionId: question.id, text: "a", inputMode: .typed)
        try await repository.saveAttempt(attempt)
        try await repository.saveEvaluation(Evaluation(attemptId: attempt.id, status: .correct, feedback: "ok", evidenceChunkIds: [chunks[0].id]))

        try await repository.deleteDocument(id: document.id)

        let deletedDocument = try await repository.document(id: document.id)
        let deletedSnapshot = try await repository.snapshot(id: snapshot.id)
        let deletedScope = try await repository.scope(id: scope.id)
        let deletedQuestion = try await repository.question(id: question.id)
        let deletedSession = try await repository.session(id: session.id)
        let remainingChunks = try await repository.chunks(snapshotId: snapshot.id)
        let remainingHistory = try await repository.history(filters: .all)
        XCTAssertNil(deletedDocument)
        XCTAssertNil(deletedSnapshot)
        XCTAssertNil(deletedScope)
        XCTAssertNil(deletedQuestion)
        XCTAssertNil(deletedSession)
        XCTAssertTrue(remainingChunks.isEmpty)
        XCTAssertTrue(remainingHistory.isEmpty)
    }

    func testClearAllStudyDataKeepsProfilesAndPromptVersions() async throws {
        let (document, _, chunks) = try await makeImport()
        let promptRepository = FileBackedPromptRepository(repository: repository, paths: paths)
        _ = try await promptRepository.activeVersion()
        let profile = ProviderProfile(name: "P", baseURL: "https://example.com/v1", modelId: "m")
        try await repository.saveProviderProfile(profile)

        try await repository.deleteAllStudyData()

        let documents = try await repository.documents()
        let absentQuestion = try await repository.question(id: QuestionID())
        let profiles = try await repository.providerProfiles()
        let versions = try await promptRepository.versions()
        XCTAssertTrue(documents.isEmpty)
        XCTAssertNil(absentQuestion)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertFalse(versions.isEmpty)
        _ = document
        _ = chunks
    }

    func testDatabaseReopensWithMigrationsApplied() async throws {
        let (document, snapshot, _) = try await makeImport()
        let reopenedDatabase = try StudyDatabase(paths: paths)
        let reopened = GRDBStudyRepository(database: reopenedDatabase)
        let reopenedDocument = try await reopened.document(id: document.id)
        let reopenedSnapshot = try await reopened.snapshot(id: snapshot.id)
        XCTAssertEqual(reopenedDocument?.name, document.name)
        XCTAssertEqual(reopenedSnapshot?.textHash, snapshot.textHash)
    }

    func testFullTextSearchProbeIsRealAndSearchWorksWhenSupported() async throws {
        let supported = await repository.isFullTextSearchSupported()
        // The probe must reflect the runtime; both outcomes are acceptable, but
        // when FTS5 exists the stored index must actually find the passage.
        let (_, snapshot, _) = try await makeImport()
        if supported {
            let ids = try await repository.searchChunkIds(query: "potassium efflux", snapshotId: snapshot.id, limit: 5)
            XCTAssertFalse(ids.isEmpty)
        } else {
            let ids = try await repository.searchChunkIds(query: "potassium efflux", snapshotId: snapshot.id, limit: 5)
            XCTAssertTrue(ids.isEmpty, "Without FTS5 the index must not pretend to exist")
        }
        XCTAssertNotNil(supported as Bool?)
    }

    func testPromptVersionsAreVersionedAndDefaultRestorable() async throws {
        let promptRepository = FileBackedPromptRepository(repository: repository, paths: paths)
        let first = try await promptRepository.activeVersion()
        XCTAssertTrue(first.isDefault)
        let edited = try await promptRepository.save(content: "# Custom\nBe terse.")
        XCTAssertFalse(edited.isDefault)
        let active = try await promptRepository.activeVersion()
        XCTAssertEqual(active.id, edited.id)
        let versionsAfterEdit = try await promptRepository.versions()
        XCTAssertEqual(versionsAfterEdit.count, 2)
        let restored = try await promptRepository.restoreDefault()
        XCTAssertTrue(restored.isDefault)
        let activeAfterRestore = try await promptRepository.activeVersion()
        XCTAssertEqual(activeAfterRestore.id, restored.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.promptFileURL.path))
    }
}
