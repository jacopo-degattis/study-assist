import XCTest
import Foundation
@testable import StudyEngine
import StudyDomain
import StudyRetrieval
import StudyPrompts
import StudyPersistence

final class ScopeAndGroundingTests: XCTestCase {
    var paths: AppPaths!
    var repository: GRDBStudyRepository!
    var prompts: FileBackedPromptRepository!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyAppGrounding-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(root: root)
        try paths.createDirectories()
        let database = try StudyDatabase(inMemory: true)
        repository = GRDBStudyRepository(database: database)
        prompts = FileBackedPromptRepository(repository: repository, paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: paths.root)
    }

    // MARK: Scope matching

    private func scopeFixture() -> [SourceChunk] {
        let snapshotId = SnapshotID()
        return [
            makeChunk(snapshotId: snapshotId, text: "Action potentials begin when voltage-gated sodium channels open and sodium enters the neuron.", page: 1, section: "Action potential", order: 0),
            makeChunk(snapshotId: snapshotId, text: "Repolarization follows as potassium channels open and potassium leaves the neuron.", page: 1, section: "Action potential", order: 1),
            makeChunk(snapshotId: snapshotId, text: "Digestion starts in the mouth, where salivary amylase breaks down starch.", page: 2, section: "Digestion", order: 2),
            makeChunk(snapshotId: snapshotId, text: "The stomach secretes hydrochloric acid that denatures proteins.", page: 2, section: "Digestion", order: 3),
        ]
    }

    private func sectionFixture(chunks: [SourceChunk]) -> [DocumentSection] {
        let titles = ["Action potential", "Digestion"]
        return titles.enumerated().map { index, title in
            DocumentSection(
                snapshotId: chunks[0].snapshotId,
                title: title,
                level: 1,
                order: index,
                location: SourceLocation(pageNumber: index + 1)
            )
        }
    }

    private func makeChunk(snapshotId: SnapshotID, text: String, page: Int, section: String, order: Int) -> SourceChunk {
        SourceChunk(
            snapshotId: snapshotId,
            text: text,
            sectionId: nil,
            location: SourceLocation(pageNumber: page, sectionTitle: section),
            startOffset: order * 100,
            endOffset: order * 100 + text.count,
            extractionMethod: .pdfText,
            quality: 1,
            isUsableAsEvidence: true,
            order: order
        )
    }

    private func matcherChunksAndSections() -> ([SourceChunk], [DocumentSection]) {
        let snapshotId = SnapshotID()
        var sections: [DocumentSection] = []
        let definitions: [(String, String)] = [
            ("Action potential", "Action potentials begin when voltage-gated sodium channels open and sodium enters the neuron. Repolarization follows as potassium channels open and potassium leaves the neuron."),
            ("Digestion", "Digestion starts in the mouth, where salivary amylase breaks down starch. The stomach secretes hydrochloric acid that denatures proteins."),
        ]
        var chunks: [SourceChunk] = []
        var order = 0
        for (index, definition) in definitions.enumerated() {
            let section = DocumentSection(
                snapshotId: snapshotId,
                title: definition.0,
                level: 1,
                order: index,
                location: SourceLocation(pageNumber: index + 1)
            )
            sections.append(section)
            for sentence in TextUtilities.sentenceSplit(definition.1) {
                chunks.append(
                    SourceChunk(
                        snapshotId: snapshotId,
                        text: sentence,
                        sectionId: section.id,
                        location: SourceLocation(pageNumber: index + 1, sectionTitle: definition.0),
                        startOffset: order * 100,
                        endOffset: order * 100 + sentence.count,
                        extractionMethod: .pdfText,
                        quality: 1,
                        isUsableAsEvidence: true,
                        order: order
                    )
                )
                order += 1
            }
        }
        return (chunks, sections)
    }

    func testScopeMatcherFindsTopicInsideTheDocument() {
        let (chunks, sections) = matcherChunksAndSections()
        let resolution = ScopeMatcher.evaluate(
            query: "action potentials",
            snapshotId: chunks[0].snapshotId,
            chunks: chunks,
            sections: sections
        )
        XCTAssertEqual(resolution.state, .found)
        XCTAssertFalse(resolution.matches.isEmpty)
        XCTAssertTrue(resolution.matches.allSatisfy { $0.sectionTitle == "Action potential" })
        XCTAssertTrue(resolution.suggestedChunkIds.allSatisfy { id in
            chunks.first { $0.id == id }?.sectionId == sections[0].id
        })
    }

    func testScopeMatcherRefusesAbsentTopicWithoutBroadening() {
        let (chunks, sections) = matcherChunksAndSections()
        let resolution = ScopeMatcher.evaluate(
            query: "photosynthesis in chloroplasts",
            snapshotId: chunks[0].snapshotId,
            chunks: chunks,
            sections: sections
        )
        XCTAssertEqual(resolution.state, .notFound)
        XCTAssertTrue(resolution.matches.isEmpty)
        XCTAssertEqual(resolution.message, ScopeResolution.notFoundMessage)
        XCTAssertEqual(resolution.message, "This topic was not found in the uploaded document.")
    }

    func testScopeMatcherMarksNearTiesAsAmbiguousForConfirmation() {
        let snapshotId = SnapshotID()
        let sections = [
            DocumentSection(snapshotId: snapshotId, title: "Membrane transport", level: 1, order: 0),
            DocumentSection(snapshotId: snapshotId, title: "Membrane potential", level: 1, order: 1),
        ]
        let chunks = [
            SourceChunk(snapshotId: snapshotId, text: "Membrane transport moves ions across the membrane.", sectionId: sections[0].id, location: SourceLocation(pageNumber: 1), startOffset: 0, endOffset: 50, extractionMethod: .pdfText, quality: 1, isUsableAsEvidence: true, order: 0),
            SourceChunk(snapshotId: snapshotId, text: "Membrane potential depends on ion gradients across the membrane.", sectionId: sections[1].id, location: SourceLocation(pageNumber: 2), startOffset: 51, endOffset: 110, extractionMethod: .pdfText, quality: 1, isUsableAsEvidence: true, order: 1),
        ]
        let resolution = ScopeMatcher.evaluate(query: "membrane", snapshotId: snapshotId, chunks: chunks, sections: sections)
        XCTAssertEqual(resolution.state, .ambiguous)
        XCTAssertTrue(resolution.state.requiresConfirmation)
        XCTAssertEqual(Set(resolution.sectionTitles), ["Membrane transport", "Membrane potential"])
    }

    func testScopeMatcherHonoursChapterNumbers() {
        let snapshotId = SnapshotID()
        let sections = [
            DocumentSection(snapshotId: snapshotId, title: "1. Introduction", level: 1, order: 0),
            DocumentSection(snapshotId: snapshotId, title: "2. Action potential", level: 1, order: 1),
            DocumentSection(snapshotId: snapshotId, title: "3. Synaptic transmission", level: 1, order: 2),
        ]
        let chunks = [
            SourceChunk(snapshotId: snapshotId, text: "This introduction mentions potentials in passing.", sectionId: sections[0].id, location: SourceLocation(pageNumber: 1), startOffset: 0, endOffset: 50, extractionMethod: .pdfText, quality: 1, isUsableAsEvidence: true, order: 0),
            SourceChunk(snapshotId: snapshotId, text: "Sodium influx depolarizes the membrane.", sectionId: sections[1].id, location: SourceLocation(pageNumber: 2), startOffset: 51, endOffset: 100, extractionMethod: .pdfText, quality: 1, isUsableAsEvidence: true, order: 1),
            SourceChunk(snapshotId: snapshotId, text: "Vesicles release neurotransmitter into the cleft.", sectionId: sections[2].id, location: SourceLocation(pageNumber: 3), startOffset: 101, endOffset: 150, extractionMethod: .pdfText, quality: 1, isUsableAsEvidence: true, order: 2),
        ]
        let resolution = ScopeMatcher.evaluate(query: "chapter 2", snapshotId: snapshotId, chunks: chunks, sections: sections)
        XCTAssertEqual(resolution.state, .found)
        XCTAssertEqual(resolution.sectionTitles, ["2. Action potential"])
        XCTAssertEqual(resolution.suggestedChunkIds, [chunks[1].id])
    }

    func testScopeMatcherRecognisesWholeDocumentRequest() {
        let (chunks, sections) = matcherChunksAndSections()
        let resolution = ScopeMatcher.evaluate(query: "entire document", snapshotId: chunks[0].snapshotId, chunks: chunks, sections: sections)
        XCTAssertEqual(resolution.state, .fullDocument)
        XCTAssertEqual(resolution.suggestedChunkIds.count, chunks.count)
    }

    // MARK: Question validation

    func testQuestionValidatorRejectsUnknownAndUnsupportedReferences() {
        let topic = Topic(snapshotId: SnapshotID(), title: "Action potential", sourceChunkIds: [], order: 0)
        let evidence = [
            SourceChunk(snapshotId: topic.snapshotId, text: "Depolarization is caused by sodium influx through voltage-gated channels.", location: SourceLocation(pageNumber: 1), startOffset: 0, endOffset: 80, extractionMethod: .pdfText, quality: 1, isUsableAsEvidence: true, order: 0),
            SourceChunk(snapshotId: topic.snapshotId, text: "Repolarization is caused by potassium efflux.", location: SourceLocation(pageNumber: 1), startOffset: 81, endOffset: 140, extractionMethod: .pdfText, quality: 1, isUsableAsEvidence: true, order: 1),
        ]
        let chunkA = evidence[0].id.rawValue
        let chunkB = evidence[1].id.rawValue

        let valid = """
        {"topicId":"\(topic.id.rawValue)","question":"What causes depolarization and repolarization?","expectedPoints":[
          {"id":"p1","text":"Depolarization is caused by sodium influx.","sourceChunkIds":["\(chunkA)"]},
          {"id":"p2","text":"Repolarization is caused by potassium efflux.","sourceChunkIds":["\(chunkB)"]}],
          "sourceChunkIds":["\(chunkA)","\(chunkB)"],"answerability":"supported"}
        """
        let validated = try? QuestionValidator.validate(
            payloadData: Data(valid.utf8),
            topic: topic,
            evidence: evidence,
            existingHashes: [],
            configuration: .default
        )
        XCTAssertNotNil(validated)
        XCTAssertEqual(validated?.rubric.expectedPoints.count, 2)

        let fabricated = valid.replacingOccurrences(of: chunkB, with: "chunk_not_supplied")
        XCTAssertThrowsError(try QuestionValidator.validate(
            payloadData: Data(fabricated.utf8),
            topic: topic,
            evidence: evidence,
            existingHashes: [],
            configuration: .default
        ))

        let unsupportedPoint = """
        {"topicId":"\(topic.id.rawValue)","question":"What is the role of calcium in the stomach?","expectedPoints":[
          {"id":"p1","text":"Calcium triggers exocytosis of synaptic vesicles.","sourceChunkIds":["\(chunkA)"]}],
          "sourceChunkIds":["\(chunkA)"],"answerability":"supported"}
        """
        XCTAssertThrowsError(try QuestionValidator.validate(
            payloadData: Data(unsupportedPoint.utf8),
            topic: topic,
            evidence: evidence,
            existingHashes: [],
            configuration: .default
        ), "A point without real overlap with its passage must be rejected")

        let duplicateHash = TextUtilities.questionHash("What causes depolarization and repolarization?")
        XCTAssertThrowsError(try QuestionValidator.validate(
            payloadData: Data(valid.utf8),
            topic: topic,
            evidence: evidence,
            existingHashes: [duplicateHash],
            configuration: .default
        ))
    }

    // MARK: Engine scope enforcement

    private struct ScopeFixture {
        var document: StudyDocument
        var snapshot: DocumentSnapshot
        var scopeA: StudyScope
        var scopeB: StudyScope
        var chunkA: SourceChunk
        var chunkB: SourceChunk
    }

    private func makeImportedDocument(chunks: [(String, String)], documentName: String) async throws -> (StudyDocument, SnapshotID, [SourceChunk]) {
        let documentId = DocumentID()
        let snapshotId = SnapshotID()
        var sections: [DocumentSection] = []
        var sectionByTitle: [String: DocumentSection] = [:]
        for (index, item) in chunks.enumerated() {
            if sectionByTitle[item.0] == nil {
                let section = DocumentSection(
                    snapshotId: snapshotId,
                    title: item.0,
                    level: 1,
                    order: sections.count,
                    location: SourceLocation(pageNumber: index + 1)
                )
                sections.append(section)
                sectionByTitle[item.0] = section
            }
        }
        var fullText = ""
        var sourceChunks: [SourceChunk] = []
        for (index, item) in chunks.enumerated() {
            if !fullText.isEmpty { fullText += "\n\n" }
            let start = fullText.utf16.count
            fullText += item.1
            let end = fullText.utf16.count
            sourceChunks.append(
                SourceChunk(
                    snapshotId: snapshotId,
                    text: item.1,
                    sectionId: sectionByTitle[item.0]?.id,
                    location: SourceLocation(pageNumber: index + 1, sectionTitle: item.0),
                    startOffset: start,
                    endOffset: end,
                    extractionMethod: .pdfText,
                    quality: 1,
                    isUsableAsEvidence: true,
                    order: index
                )
            )
        }
        let quality = DocumentQuality(
            pagesProcessed: chunks.count,
            pagesRequiringOCR: 0,
            pagesUnreadable: 0,
            paragraphsExtracted: chunks.count,
            charactersExtracted: fullText.count,
            warnings: []
        )
        let snapshot = DocumentSnapshot(
            id: snapshotId,
            documentId: documentId,
            version: 1,
            textHash: TextUtilities.sha256Hex(fullText),
            quality: quality
        )
        let document = StudyDocument(
            id: documentId,
            name: documentName,
            fileType: .pdf,
            storedFileName: "\(documentId.rawValue).pdf",
            sha256: "hash-\(documentId.rawValue)",
            state: .ready,
            language: "en",
            parserVersion: "test",
            activeSnapshotId: snapshotId
        )
        let result = DocumentImportResult(
            documentName: documentName,
            fileType: .pdf,
            fileHash: document.sha256,
            textHash: snapshot.textHash,
            storedFileName: document.storedFileName,
            snapshot: snapshot,
            sections: sections,
            chunks: sourceChunks,
            fullText: fullText,
            language: "en",
            parserVersion: "test"
        )
        try await repository.saveImport(result, document: document)
        return (document, snapshotId, sourceChunks)
    }

    func testTopicCatalogIsBuiltForAReadyDocumentWithoutStartingASession() async throws {
        let (_, snapshotId, chunks) = try await makeImportedDocument(
            chunks: [
                ("Action potential", "Depolarization is caused by sodium influx through voltage-gated channels."),
                ("Digestion", "Salivary amylase begins starch digestion in the mouth."),
            ],
            documentName: "Catalog"
        )
        let initial = try await repository.topics(snapshotId: snapshotId)
        XCTAssertTrue(initial.isEmpty, "Topics are built locally when the document becomes ready")

        let built = try await TopicCatalogBuilder.ensureTopics(repository: repository, snapshotId: snapshotId)
        XCTAssertFalse(built.isEmpty, "A document with usable passages must not be blocked as having no topics")
        XCTAssertTrue(built.allSatisfy { !$0.sourceChunkIds.isEmpty })
        XCTAssertEqual(Set(built.flatMap(\.sourceChunkIds)), Set(chunks.map(\.id)))

        let again = try await TopicCatalogBuilder.ensureTopics(repository: repository, snapshotId: snapshotId)
        XCTAssertEqual(again.map(\.id), built.map(\.id), "Cataloging is idempotent")
    }

    func testEngineQuestionsStayInsideTheConfirmedScope() async throws {
        let (document, snapshotId, chunks) = try await makeImportedDocument(
            chunks: [
                ("Action potential", "Depolarization is caused by sodium influx through voltage-gated channels. Repolarization is caused by potassium efflux from the neuron."),
                ("Digestion", "Salivary amylase begins starch digestion in the mouth. The stomach secretes hydrochloric acid."),
            ],
            documentName: "Neurophysiology"
        )
        let actionChunk = chunks.first { $0.location.sectionTitle == "Action potential" }!
        let digestionChunk = chunks.first { $0.location.sectionTitle == "Digestion" }!

        let scope = try await StudyScopeResolver(repository: repository).makeScope(
            query: "action potential",
            snapshotId: snapshotId,
            chunkIds: [actionChunk.id],
            title: "Action potential",
            confirmedByUser: true
        )

        let questionJSON = """
        {"topicId":"__TOPIC__","question":"What causes the depolarization phase of the action potential?","expectedPoints":[
          {"id":"p1","text":"Depolarization is caused by sodium influx through voltage-gated channels.","sourceChunkIds":["\(actionChunk.id.rawValue)"]}],
          "sourceChunkIds":["\(actionChunk.id.rawValue)"],"answerability":"supported"}
        """
        let provider = try MockLLMProvider(profile: makeProfile(), scripted: [.success(questionJSON)])
        let engine = makeEngine(provider: provider)

        let session = try await engine.startSession(documentId: document.id, mode: .fullStudy, scopeId: scope.id)

        // Resolve the topic the engine will choose so the scripted answer matches it.
        let topics = try await repository.topics(snapshotId: snapshotId)
        let topic = try XCTUnwrap(topics.first)
        await provider.replaceScript([.success(questionJSON.replacingOccurrences(of: "__TOPIC__", with: topic.id.rawValue))])

        let prepared = try await engine.nextQuestion(sessionId: session.id)
        XCTAssertEqual(prepared.question.scopeId, scope.id)
        XCTAssertTrue(prepared.question.rubric.sourceChunkIds.allSatisfy { $0 == actionChunk.id })
        XCTAssertFalse(prepared.question.text.contains("starch"))

        let prompt = await provider.lastRequest?.user ?? ""
        XCTAssertTrue(prompt.contains(actionChunk.text), "The in-scope passage must be supplied")
        XCTAssertFalse(prompt.contains(digestionChunk.text), "Out-of-scope passages must never be supplied")
    }

    func testEngineRefusesToGradeEvidenceOutsideTheQuestionScope() async throws {
        let (document, snapshotId, chunks) = try await makeImportedDocument(
            chunks: [
                ("Action potential", "Depolarization is caused by sodium influx. Repolarization is caused by potassium efflux."),
                ("Digestion", "Salivary amylase begins starch digestion in the mouth."),
            ],
            documentName: "Neurophysiology"
        )
        let actionChunk = chunks.first { $0.location.sectionTitle == "Action potential" }!
        let digestionChunk = chunks.first { $0.location.sectionTitle == "Digestion" }!
        let scope = try await StudyScopeResolver(repository: repository).makeScope(
            query: "action potential",
            snapshotId: snapshotId,
            chunkIds: [actionChunk.id],
            confirmedByUser: true
        )

        let provider = try MockLLMProvider(profile: makeProfile(), scripted: [])
        let engine = makeEngine(provider: provider)
        let session = try await engine.startSession(documentId: document.id, mode: .fullStudy, scopeId: scope.id)

        // A question that cites an out-of-scope passage must be refused even if
        // the session were to contain it.
        let topics = try await repository.topics(snapshotId: snapshotId)
        let topic = try XCTUnwrap(topics.first)
        let question = Question(
            sessionId: session.id,
            topicId: topic.id,
            text: "What begins starch digestion?",
            rubric: QuestionRubric(
                expectedPoints: [
                    ExpectedPoint(id: "p1", text: "Salivary amylase begins starch digestion.", sourceChunkIds: [digestionChunk.id])
                ],
                sourceChunkIds: [digestionChunk.id],
                answerability: .supported
            ),
            normalizedTextHash: "hash",
            scopeId: scope.id
        )
        try await repository.saveQuestion(question)

        do {
            _ = try await engine.submitAnswer(questionId: question.id, text: "Amylase", inputMode: .typed)
            XCTFail("An out-of-scope question must not be graded")
        } catch let error as AppError {
            guard case .insufficientEvidence = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let attempts = try await repository.attempts(questionId: question.id)
        XCTAssertTrue(attempts.isEmpty, "A refused grading must not leave a history entry")
    }

    func testChangingFocusDoesNotMoveExistingQuestions() async throws {
        let (document, snapshotId, chunks) = try await makeImportedDocument(
            chunks: [
                ("Action potential", "Depolarization is caused by sodium influx through voltage-gated channels."),
                ("Digestion", "Salivary amylase begins starch digestion in the mouth."),
            ],
            documentName: "Neurophysiology"
        )
        let actionChunk = chunks.first { $0.location.sectionTitle == "Action potential" }!
        let digestionChunk = chunks.first { $0.location.sectionTitle == "Digestion" }!
        let resolver = StudyScopeResolver(repository: repository)
        let scopeA = try await resolver.makeScope(query: "action potential", snapshotId: snapshotId, chunkIds: [actionChunk.id], confirmedByUser: true)
        let scopeB = try await resolver.makeScope(query: "digestion", snapshotId: snapshotId, chunkIds: [digestionChunk.id], confirmedByUser: true)

        let questionJSON = """
        {"topicId":"__TOPIC__","question":"What causes depolarization?","expectedPoints":[
          {"id":"p1","text":"Depolarization is caused by sodium influx through voltage-gated channels.","sourceChunkIds":["\(actionChunk.id.rawValue)"]}],
          "sourceChunkIds":["\(actionChunk.id.rawValue)"],"answerability":"supported"}
        """
        let provider = try MockLLMProvider(profile: makeProfile(), scripted: [])
        let engine = makeEngine(provider: provider)
        let session = try await engine.startSession(documentId: document.id, mode: .fullStudy, scopeId: scopeA.id)
        let allTopics = try await repository.topics(snapshotId: snapshotId)
        let topic = try XCTUnwrap(allTopics.first { $0.sourceChunkIds.contains(actionChunk.id) })
        await provider.replaceScript([.success(questionJSON.replacingOccurrences(of: "__TOPIC__", with: topic.id.rawValue))])
        let first = try await engine.nextQuestion(sessionId: session.id)

        _ = try await engine.changeSessionScope(sessionId: session.id, scopeId: scopeB.id)
        let reloaded = try await repository.question(id: first.question.id)
        XCTAssertEqual(reloaded?.scopeId, scopeA.id, "An existing question keeps its original scope")

        // The next question must be drawn from the new focus.
        let topicsAfterChange = try await repository.topics(snapshotId: snapshotId)
        let digestionTopic = try XCTUnwrap(topicsAfterChange.first { $0.sourceChunkIds.contains(digestionChunk.id) })
        let secondJSON = """
        {"topicId":"\(digestionTopic.id.rawValue)","question":"Where does starch digestion begin?","expectedPoints":[
          {"id":"p1","text":"Salivary amylase begins starch digestion in the mouth.","sourceChunkIds":["\(digestionChunk.id.rawValue)"]}],
          "sourceChunkIds":["\(digestionChunk.id.rawValue)"],"answerability":"supported"}
        """
        await provider.replaceScript([.success(secondJSON)])
        let second = try await engine.nextQuestion(sessionId: session.id)
        XCTAssertEqual(second.question.scopeId, scopeB.id)
        XCTAssertTrue(second.question.rubric.sourceChunkIds.allSatisfy { $0 == digestionChunk.id })
    }

    func testScopeResolverPersistsOnlyRealUsableChunks() async throws {
        let (_, snapshotId, chunks) = try await makeImportedDocument(
            chunks: [("Action potential", "Depolarization is caused by sodium influx.")],
            documentName: "Neurophysiology"
        )
        let resolver = StudyScopeResolver(repository: repository)
        let foreign = ChunkID()
        let scope = try await resolver.makeScope(
            query: "action potential",
            snapshotId: snapshotId,
            chunkIds: [foreign, chunks[0].id],
            confirmedByUser: true
        )
        XCTAssertEqual(scope.matchedChunkIds, [chunks[0].id])
        let stored = try await repository.scope(id: scope.id)
        XCTAssertEqual(stored?.id, scope.id)
        XCTAssertEqual(stored?.matchedChunkIds, scope.matchedChunkIds)
        XCTAssertEqual(stored?.version, scope.version)
        XCTAssertEqual(scope.version, 1)
        XCTAssertTrue(scope.confirmedByUser)
    }

    // MARK: Helpers

    private func makeProfile() -> ProviderProfile {
        ProviderProfile(name: "Test", baseURL: "https://example.invalid/v1", modelId: "test-model")
    }

    private func makeEngine(provider: MockLLMProvider) -> StudyEngine {
        StudyEngine(
            repository: repository,
            retriever: LocalEvidenceRetriever(repository: repository),
            prompts: prompts,
            providerResolver: { _ in provider },
            configuration: .default
        )
    }
}

// MARK: - Mock provider

actor MockLLMProvider: LLMProvider {
    nonisolated let profile: ProviderProfile
    private var scripted: [Result<String, AppError>]
    private(set) var requests: [LLMRequest] = []

    init(profile: ProviderProfile, scripted: [Result<String, AppError>]) {
        self.profile = profile
        self.scripted = scripted
    }

    var lastRequest: LLMRequest? { requests.last }

    func replaceScript(_ script: [Result<String, AppError>]) {
        scripted = script
    }

    func testConnection() async throws -> ConnectionTestResult {
        ConnectionTestResult(modelId: profile.modelId, latency: 0.01, responseFormatSupported: true, detail: "mock")
    }

    func complete(_ request: LLMRequest) async throws -> LLMCompletion {
        requests.append(request)
        guard !scripted.isEmpty else {
            throw AppError.providerMalformedResponse("No scripted response left.")
        }
        switch scripted.removeFirst() {
        case .success(let text):
            return LLMCompletion(
                text: text,
                modelId: profile.modelId,
                providerProfileId: profile.id,
                latency: 0.01,
                responseFormatUsed: request.responseFormat
            )
        case .failure(let error):
            throw error
        }
    }
}
