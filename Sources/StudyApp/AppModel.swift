import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StudyDomain
import StudyPersistence
import StudyDocuments
import StudyRetrieval
import StudyPrompts
import StudyProviders
import StudyEngine
import StudySpeech

public enum SidebarSection: Hashable {
    case documents
    case history
    case settings
}

struct ImportStatus: Equatable {
    var phase: String
    var fraction: Double?
}

@MainActor
final class AppModel: ObservableObject {
    let paths: AppPaths
    let database: StudyDatabase
    let repository: GRDBStudyRepository
    let prompts: FileBackedPromptRepository
    let secretStore: any SecretStore
    let engine: StudyEngine
    let speechManager: SpeechModelManager
    let fileStore: DocumentFileStore

    @Published var documents: [DocumentSummary] = []
    @Published var selectedDocumentID: DocumentID?
    @Published var sidebarSelection: SidebarSection = .documents
    @Published var importing: ImportStatus?
    @Published var libraryError: String?
    @Published var notice: String?

    @Published var providerProfiles: [ProviderProfile] = []
    @Published var activeProviderID: ProviderProfileID?
    @Published var speechProfiles: [SpeechProfile] = []
    @Published var activeSpeechProfile: SpeechProfile?
    @Published var speechCatalog: [SpeechEngineStatus] = []
    @Published var promptVersion: PromptVersion?
    @Published var promptVersions: [PromptVersion] = []
    @Published var promptContent: String = ""
    @Published var hasCompletedOnboarding: Bool = true
    @Published var study: StudyViewModel?
    @Published var readyDocument: ReadyDocument?

    struct ReadyDocument: Equatable {
        var document: StudyDocument
        var snapshotId: SnapshotID
        var quality: DocumentQuality
        var sectionCount: Int
        var topicCount: Int
        var activeSessionID: SessionID?
        var lastSession: StudySession?
        var weakTopicCount: Int
    }

    /// Published only when the on-disk library cannot be opened; the app then
    /// runs against an in-memory store so the failure is visible, not fatal.
    @Published var startupError: String?

    convenience init(paths: AppPaths = .standard()) throws {
        try paths.createDirectories()
        let database = try StudyDatabase(paths: paths)
        self.init(database: database, paths: paths, startupError: nil)
    }

    private static func fallback(error: Error) -> AppModel {
        let paths = AppPaths.standard()
        let database: StudyDatabase
        do {
            database = try StudyDatabase(inMemory: true)
        } catch {
            fatalError("The in-memory database could not be created: \(error)")
        }
        return AppModel(
            database: database,
            paths: paths,
            startupError: "The library could not be opened, so this session is temporary. \(error.localizedDescription)"
        )
    }

    static func makeStandard() -> AppModel {
        do {
            return try AppModel(paths: .standard())
        } catch {
            return fallback(error: error)
        }
    }

    private init(database: StudyDatabase, paths: AppPaths, startupError: String?) {
        self.paths = paths
        self.database = database
        self.startupError = startupError
        let repository = GRDBStudyRepository(database: database)
        self.repository = repository
        self.fileStore = DocumentFileStore(paths: paths)
        self.prompts = FileBackedPromptRepository(repository: repository, paths: paths)
        let secretStore = KeychainSecretStore()
        self.secretStore = secretStore
        let retriever = LocalEvidenceRetriever(repository: repository)
        self.engine = StudyEngine(
            repository: repository,
            retriever: retriever,
            prompts: prompts,
            providerResolver: { profileID in
                let profile: ProviderProfile?
                if let profileID {
                    profile = try await repository.providerProfile(id: profileID)
                    if profile == nil {
                        throw AppError.providerNotConfigured
                    }
                } else {
                    profile = try await repository.activeProviderProfile()
                }
                guard let profile else { throw AppError.providerNotConfigured }
                return try LLMProviderFactory.makeProvider(profile: profile, secretStore: secretStore)
            }
        )
        self.speechManager = SpeechModelManager(
            modelsRoot: paths.root.appendingPathComponent("SpeechModels", isDirectory: true),
            secretStore: secretStore
        )
        paths.clearTemporaryAudio()
    }

    func bootstrap() async {
        await refreshDocuments()
        await refreshProviderProfiles()
        await refreshSpeechProfiles()
        await refreshPrompt()
        await refreshSpeechCatalog()
        hasCompletedOnboarding = (try? await repository.setting(key: SettingKey.hasCompletedOnboarding)) == "true"
        if !hasCompletedOnboarding, (try? await repository.providerProfiles().isEmpty) == true {
            hasCompletedOnboarding = false
        }
    }

    // MARK: Library

    func refreshDocuments() async {
        do {
            documents = try await repository.documentSummaries()
            // A ready document must have its local topic catalog. Without this,
            // the ready screen would block a perfectly usable document until a
            // session happened to start.
            var cataloguedAny = false
            for summary in documents where summary.document.state == .ready && summary.topicCount == 0 {
                guard let snapshotId = summary.document.activeSnapshotId else { continue }
                let topics = (try? await TopicCatalogBuilder.ensureTopics(repository: repository, snapshotId: snapshotId)) ?? []
                if !topics.isEmpty { cataloguedAny = true }
            }
            if cataloguedAny {
                documents = try await repository.documentSummaries()
            }
            if let selectedDocumentID, !documents.contains(where: { $0.document.id == selectedDocumentID }) {
                self.selectedDocumentID = nil
                readyDocument = nil
            }
        } catch {
            libraryError = message(for: error)
        }
    }

    func importDocument(from url: URL) async {
        libraryError = nil
        notice = nil
        guard let fileType = DocumentImporterFactory.fileType(for: url) else {
            libraryError = AppError.documentUnsupportedType("Choose a .pdf or .docx file.").userMessage
            return
        }
        do {
            let hash = try FileHashing.sha256(of: url)
            if let existing = try await repository.documents().first(where: { $0.sha256 == hash && $0.state == .ready }) {
                notice = "This file is already in the library."
                await selectDocument(existing.id)
                return
            }
        } catch {
            libraryError = message(for: error)
            return
        }

        let documentId = DocumentID()
        let fileName = "\(documentId.rawValue).\(fileType.fileExtensions.first ?? "dat")"
        let destination = paths.documentsDirectory.appendingPathComponent(fileName)
        let request = DocumentImportRequest(
            sourceURL: url,
            destinationURL: destination,
            documentId: documentId,
            documentName: url.deletingPathExtension().lastPathComponent
        )
        importing = ImportStatus(phase: "Starting import", fraction: 0)

        let importer = DocumentImporterFactory.importer(for: fileType)
        do {
            let result = try await importer.importDocument(request, progress: { [weak self] progress in
                Task { @MainActor in
                    self?.importing = ImportStatus(phase: progress.phase, fraction: progress.fraction)
                }
            })
            let document = StudyDocument(
                id: documentId,
                name: request.documentName,
                fileType: fileType,
                storedFileName: result.storedFileName,
                sha256: result.fileHash,
                state: .ready,
                language: result.language,
                parserVersion: result.parserVersion,
                activeSnapshotId: result.snapshot.id
            )
            try await repository.saveImport(result, document: document)
            importing = nil
            await refreshDocuments()
            await selectDocument(documentId)
        } catch {
            importing = nil
            try? FileManager.default.removeItem(at: destination)
            libraryError = message(for: error)
        }
    }

    /// Re-imports a changed file as a new snapshot of the same document.
    /// Earlier questions, scopes and answers stay attached to the old snapshot.
    func reimportDocument(_ id: DocumentID, from url: URL) async {
        libraryError = nil
        guard let existing = try? await repository.document(id: id),
              let fileType = DocumentImporterFactory.fileType(for: url) else {
            libraryError = AppError.documentUnsupportedType("Choose a .pdf or .docx file.").userMessage
            return
        }
        guard fileType == existing.fileType else {
            libraryError = AppError.documentImportFailed("The replacement file is a different type. Import it as a new document instead.").userMessage
            return
        }
        importing = ImportStatus(phase: "Re-importing as a new version", fraction: 0)
        let destination = paths.documentsDirectory.appendingPathComponent(existing.storedFileName)
        let request = DocumentImportRequest(
            sourceURL: url,
            destinationURL: destination,
            documentId: id,
            documentName: url.deletingPathExtension().lastPathComponent
        )
        do {
            let importer = DocumentImporterFactory.importer(for: fileType)
            let result = try await importer.importDocument(request, progress: { [weak self] progress in
                Task { @MainActor in
                    self?.importing = ImportStatus(phase: progress.phase, fraction: progress.fraction)
                }
            })
            let previous = try await repository.snapshots(documentId: id)
            var snapshot = result.snapshot
            snapshot.documentId = id
            snapshot.version = (previous.map(\.version).max() ?? 0) + 1
            let versioned = DocumentImportResult(
                documentName: result.documentName,
                fileType: result.fileType,
                fileHash: result.fileHash,
                textHash: result.textHash,
                storedFileName: result.storedFileName,
                snapshot: snapshot,
                sections: result.sections,
                chunks: result.chunks,
                fullText: result.fullText,
                language: result.language,
                parserVersion: result.parserVersion
            )
            var updated = existing
            updated.name = request.documentName.isEmpty ? existing.name : request.documentName
            updated.sha256 = result.fileHash
            updated.importedAt = Date()
            updated.state = .ready
            updated.language = result.language
            updated.parserVersion = result.parserVersion
            updated.activeSnapshotId = snapshot.id
            try await repository.saveImport(versioned, document: updated)
            importing = nil
            await refreshDocuments()
            await selectDocument(id)
            notice = "Imported version \(snapshot.version) of this document. Earlier answers keep their original version."
        } catch {
            importing = nil
            libraryError = message(for: error)
        }
    }

    func requestReplacePanel(for documentId: DocumentID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "docx") ?? .data]
        panel.prompt = "Import version"
        panel.message = "Choose the updated PDF or DOCX. It becomes a new version; history keeps the old one."
        if panel.runModal() == .OK, let url = panel.url {
            Task { await reimportDocument(documentId, from: url) }
        }
    }

    func selectDocument(_ id: DocumentID) async {
        selectedDocumentID = id
        sidebarSelection = .documents
        study = nil
        guard var summary = documents.first(where: { $0.document.id == id }) else {
            readyDocument = nil
            return
        }
        if summary.topicCount == 0, let snapshotId = summary.document.activeSnapshotId {
            let topics = (try? await TopicCatalogBuilder.ensureTopics(repository: repository, snapshotId: snapshotId)) ?? []
            if !topics.isEmpty {
                await refreshDocuments()
                if let refreshed = documents.first(where: { $0.document.id == id }) {
                    summary = refreshed
                }
            }
        }
        let snapshotId = summary.document.activeSnapshotId
        var weak: [TopicPerformance] = []
        if let snapshotId {
            weak = (try? await engine.weakTopics(snapshotId: snapshotId)) ?? []
        }
        let active = try? await repository.activeSession(for: id)
        let sessions = (try? await repository.sessions(documentId: id)) ?? []
        guard let snapshotId = summary.document.activeSnapshotId else {
            readyDocument = nil
            libraryError = AppError.documentNoActiveSnapshot.userMessage
            return
        }
        readyDocument = ReadyDocument(
            document: summary.document,
            snapshotId: snapshotId,
            quality: summary.quality ?? DocumentQuality(),
            sectionCount: summary.sectionCount,
            topicCount: summary.topicCount,
            activeSessionID: active?.id,
            lastSession: sessions.first,
            weakTopicCount: weak.count
        )
    }

    func startStudy(mode: SessionMode, scopeId: ScopeID? = nil) async {
        guard let readyDocument else { return }
        libraryError = nil
        do {
            let session = try await engine.startSession(
                documentId: readyDocument.document.id,
                mode: mode,
                scopeId: scopeId
            )
            try await beginStudyView(session: session, document: readyDocument.document)
        } catch {
            libraryError = message(for: error)
        }
    }

    func resumeStudy() async {
        guard let readyDocument, let sessionID = readyDocument.activeSessionID else { return }
        do {
            guard let session = try await repository.session(id: sessionID) else {
                libraryError = AppError.invalidStateTransition("The session no longer exists.").userMessage
                return
            }
            try await beginStudyView(session: session, document: readyDocument.document)
        } catch {
            libraryError = message(for: error)
        }
    }

    private func beginStudyView(session: StudySession, document: StudyDocument) async throws {
        let model = StudyViewModel(
            engine: engine,
            repository: repository,
            speechManager: speechManager,
            session: session,
            document: document,
            paths: paths,
            speechProfile: activeSpeechProfile
        )
        study = model
        await model.load()
    }

    func endStudy() async {
        await study?.cancelWork()
        study = nil
        await refreshDocuments()
        if let selectedDocumentID {
            await selectDocument(selectedDocumentID)
        }
    }

    func deleteDocument(_ id: DocumentID) async {
        do {
            if let document = try await repository.document(id: id) {
                try await repository.deleteDocument(id: id)
                fileStore.delete(storedFileName: document.storedFileName)
            }
            if selectedDocumentID == id {
                selectedDocumentID = nil
                readyDocument = nil
                study = nil
            }
            await refreshDocuments()
        } catch {
            libraryError = message(for: error)
        }
    }

    // MARK: Onboarding

    func completeOnboarding() async {
        hasCompletedOnboarding = true
        try? await repository.setSetting(key: SettingKey.hasCompletedOnboarding, value: "true")
    }

    func skipOnboarding() async {
        await completeOnboarding()
    }

    // MARK: File panel

    func requestImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "docx") ?? .data]
        panel.prompt = "Import"
        panel.message = "Choose a PDF or DOCX document to study."
        if panel.runModal() == .OK, let url = panel.url {
            Task { await importDocument(from: url) }
        }
    }

    // MARK: Helpers

    func message(for error: Error) -> String {
        if let appError = error as? AppError { return appError.userMessage }
        if error is CancellationError { return AppError.operationCancelled.userMessage }
        return error.localizedDescription
    }
}
