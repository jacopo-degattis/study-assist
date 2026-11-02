import Foundation
import StudyDomain
import StudyProviders
import StudySpeech

// MARK: - Provider profiles

extension AppModel {
    func refreshProviderProfiles() async {
        providerProfiles = (try? await repository.providerProfiles()) ?? []
        activeProviderID = (try? await repository.activeProviderProfile())?.id
    }

    var activeProvider: ProviderProfile? {
        guard let activeProviderID else { return nil }
        return providerProfiles.first { $0.id == activeProviderID }
    }

    @discardableResult
    func saveProvider(name: String, baseURL: String, style: ProviderAPIStyle, modelId: String, apiKey: String?, requiresAuthentication: Bool, extraHeaders: [String: String], timeoutSeconds: Double, maxRetries: Int, existingID: ProviderProfileID? = nil) async throws -> ProviderProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw AppError.validationFailed("Give the provider profile a name.")
        }
        guard !trimmedModel.isEmpty else {
            throw AppError.validationFailed("Enter the exact model ID.")
        }
        _ = try ProviderEndpoint.validateBaseURL(baseURL)
        guard timeoutSeconds >= 5, timeoutSeconds <= 300 else {
            throw AppError.validationFailed("The timeout must be between 5 and 300 seconds.")
        }
        guard (0...5).contains(maxRetries) else {
            throw AppError.validationFailed("Retries must be between 0 and 5.")
        }
        var headers: [String: String] = [:]
        for (key, value) in extraHeaders {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            guard !trimmedKey.isEmpty, !value.isEmpty else { continue }
            guard trimmedKey.lowercased() != "authorization" else {
                throw AppError.validationFailed("Do not set Authorization as an extra header; the API key is stored separately in the Keychain.")
            }
            headers[trimmedKey] = value
        }

        let existing = existingID.flatMap { id in providerProfiles.first { $0.id == id } }
            ?? providerProfiles.first { $0.name == trimmedName }
        var profile = ProviderProfile(
            id: existing?.id ?? ProviderProfileID(),
            name: trimmedName,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiStyle: style,
            modelId: trimmedModel,
            keychainRef: existing?.keychainRef,
            requiresAuthentication: requiresAuthentication,
            extraHeaders: headers,
            timeoutSeconds: timeoutSeconds,
            maxRetries: maxRetries,
            createdAt: existing?.createdAt ?? Date(),
            lastConnectionTest: existing?.lastConnectionTest,
            lastConnectionSucceeded: existing?.lastConnectionSucceeded
        )
        if let apiKey {
            try ProviderCredentials.applyAPIKey(apiKey, to: &profile, secretStore: secretStore)
        } else if !requiresAuthentication {
            try ProviderCredentials.applyAPIKey(nil, to: &profile, secretStore: secretStore)
        }
        try await repository.saveProviderProfile(profile)
        if activeProviderID == nil {
            try await repository.setActiveProviderProfile(profile.id)
        }
        await refreshProviderProfiles()
        return profile
    }

    func deleteProvider(_ id: ProviderProfileID) async {
        if let profile = providerProfiles.first(where: { $0.id == id }) {
            ProviderCredentials.removeAPIKey(for: profile, secretStore: secretStore)
        }
        try? await repository.deleteProviderProfile(id: id)
        await refreshProviderProfiles()
    }

    func setActiveProvider(_ id: ProviderProfileID?) async {
        try? await repository.setActiveProviderProfile(id)
        await refreshProviderProfiles()
    }

    func hasAPIKey(for profile: ProviderProfile) -> Bool {
        (try? ProviderCredentials.apiKey(for: profile, secretStore: secretStore))?.isEmpty == false
    }

    func testConnection(for profile: ProviderProfile) async -> Result<ConnectionTestResult, Error> {
        var updated = profile
        updated.lastConnectionTest = Date()
        do {
            let provider = try LLMProviderFactory.makeProvider(profile: profile, secretStore: secretStore)
            let result = try await provider.testConnection()
            updated.lastConnectionSucceeded = true
            try? await repository.saveProviderProfile(updated)
            await refreshProviderProfiles()
            return .success(result)
        } catch {
            updated.lastConnectionSucceeded = false
            try? await repository.saveProviderProfile(updated)
            await refreshProviderProfiles()
            return .failure(error)
        }
    }
}

// MARK: - Speech profiles

extension AppModel {
    var speechModelsRoot: URL {
        paths.root.appendingPathComponent("SpeechModels", isDirectory: true)
    }

    func refreshSpeechProfiles() async {
        speechProfiles = (try? await repository.speechProfiles()) ?? []
        activeSpeechProfile = (try? await repository.activeSpeechProfile())
    }

    func refreshSpeechCatalog() async {
        speechCatalog = await SpeechTranscriberFactory.catalog(modelsRoot: speechModelsRoot)
    }

    @discardableResult
    func saveSpeechProfile(engine: SpeechEngine, language: String?, modelId: String?, remoteBaseURL: String?, apiKey: String?) async throws -> SpeechProfile {
        var remoteURL: String?
        if engine == .customEndpoint {
            guard let remoteBaseURL, !remoteBaseURL.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw AppError.validationFailed("Enter the transcription endpoint URL.")
            }
            _ = try ProviderEndpoint.transcriptionEndpointURL(baseURL: remoteBaseURL)
            remoteURL = remoteBaseURL
        }
        var profile = SpeechProfile(
            engine: engine,
            modelId: modelId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            language: language?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            remoteBaseURL: remoteURL
        )
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            let reference = ProviderCredentials.speechReference(for: profile.id)
            try secretStore.store(secret: apiKey, for: reference)
            profile.keychainRef = reference
        }
        try await repository.saveSpeechProfile(profile)
        if activeSpeechProfile == nil {
            try await repository.setActiveSpeechProfile(profile.id)
        }
        await refreshSpeechProfiles()
        return profile
    }

    func setActiveSpeechProfile(_ id: SpeechProfileID?) async {
        try? await repository.setActiveSpeechProfile(id)
        await refreshSpeechProfiles()
    }

    func deleteSpeechProfile(_ id: SpeechProfileID) async {
        if let profile = speechProfiles.first(where: { $0.id == id }) {
            if let ref = profile.keychainRef {
                try? secretStore.deleteSecret(for: ref)
            }
            try? await speechManager.remove(profile: profile)
        }
        try? await repository.deleteSpeechProfile(id: id)
        await refreshSpeechProfiles()
    }

    func installSpeechModel(profile: SpeechProfile, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await speechManager.install(profile: profile, progress: progress)
        await refreshSpeechCatalog()
    }

    func removeSpeechModel(profile: SpeechProfile) async throws {
        try await speechManager.remove(profile: profile)
        await refreshSpeechCatalog()
    }
}

// MARK: - Tutor instructions

extension AppModel {
    func refreshPrompt() async {
        do {
            promptVersion = try await prompts.activeVersion()
            promptVersions = try await prompts.versions()
            promptContent = promptVersion?.content ?? prompts.defaultContent()
        } catch {
            libraryError = message(for: error)
        }
    }

    func savePrompt(_ content: String) async throws {
        _ = try await prompts.save(content: content)
        await refreshPrompt()
    }

    func restoreDefaultPrompt() async throws {
        _ = try await prompts.restoreDefault()
        await refreshPrompt()
    }
}

// MARK: - Data management

extension AppModel {
    var storageLocation: String { paths.root.path }

    func clearStudyData() async {
        await study?.cancelWork()
        study = nil
        selectedDocumentID = nil
        readyDocument = nil
        try? await repository.deleteAllStudyData()
        fileStore.deleteAll()
        paths.clearTemporaryAudio()
        await refreshDocuments()
    }

    func clearTemporaryAudio() {
        paths.clearTemporaryAudio()
    }
}

extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
