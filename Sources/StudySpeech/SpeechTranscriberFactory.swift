import Foundation
import StudyDomain
import StudyProviders

/// An engine that is listed only when this build genuinely cannot run it.
/// The detail string is shown in Settings so the limitation is never hidden.
public struct UnavailableSpeechTranscriber: SpeechTranscriber {
    public let engine: SpeechEngine
    public let reason: String

    public init(engine: SpeechEngine, reason: String) {
        self.engine = engine
        self.reason = reason
    }

    public func availability() async -> TranscriberAvailability {
        TranscriberAvailability(isAvailable: false, requiresDownload: false, detail: reason)
    }

    public func transcribe(audioAt url: URL) async throws -> TranscriptionResult {
        throw AppError.speechEngineUnavailable(reason)
    }
}

/// Builds the transcriber for a speech profile. Local engines never fall back
/// to a remote service; a missing model is an error, not a silent substitution.
public enum SpeechTranscriberFactory {
    public static func makeTranscriber(
        profile: SpeechProfile,
        secretStore: any SecretStore,
        modelsRoot: URL
    ) -> any SpeechTranscriber {
        switch profile.engine {
        case .appleOnDevice:
            return AppleSpeechTranscriber(languageCode: profile.language)

        case .customEndpoint:
            let key = profile.keychainRef.flatMap { try? secretStore.secret(for: $0) }
            return RemoteSpeechTranscriber(profile: profile, apiKey: key)

        case .parakeetUltra, .parakeetTDTv3, .parakeetTDTv2, .parakeetTDTCTC110M, .parakeetJapanese:
            return ParakeetSpeechTranscriber(
                engine: profile.engine,
                languageCode: profile.language,
                modelsRoot: modelsRoot
            )

        case .whisperLargeV3Turbo, .whisperLargeV3TurboCompressed, .whisperSmall:
            return UnavailableSpeechTranscriber(
                engine: profile.engine,
                reason: "\(profile.engine.displayName) is not included in this build. WhisperKit is not linked, so the engine cannot be offered as working."
            )
        }
    }

    /// Engines that this build can actually offer, with their honest status.
    public static func catalog(modelsRoot: URL) async -> [SpeechEngineStatus] {
        var statuses: [SpeechEngineStatus] = []
        for engine in SpeechEngine.allCases {
            let profile = SpeechProfile(engine: engine)
            let transcriber = makeTranscriber(profile: profile, secretStore: InMemorySecretStore(), modelsRoot: modelsRoot)
            let availability = await transcriber.availability()
            statuses.append(
                SpeechEngineStatus(
                    engine: engine,
                    availability: availability,
                    note: engine.supportedLanguageNote
                )
            )
        }
        return statuses
    }
}

public struct SpeechEngineStatus: Sendable, Identifiable, Hashable {
    public var engine: SpeechEngine
    public var availability: TranscriberAvailability
    public var note: String

    public var id: String { engine.rawValue }

    public init(engine: SpeechEngine, availability: TranscriberAvailability, note: String) {
        self.engine = engine
        self.availability = availability
        self.note = note
    }
}

/// Loads and caches the selected local model on demand, and manages downloads.
public actor SpeechModelManager {
    private let modelsRoot: URL
    private var loaded: [SpeechEngine: any SpeechTranscriber] = [:]
    private let secretStore: any SecretStore

    public init(modelsRoot: URL, secretStore: any SecretStore) {
        self.modelsRoot = modelsRoot
        self.secretStore = secretStore
    }

    public func transcriber(for profile: SpeechProfile) -> any SpeechTranscriber {
        if let existing = loaded[profile.engine] { return existing }
        let transcriber = SpeechTranscriberFactory.makeTranscriber(
            profile: profile,
            secretStore: secretStore,
            modelsRoot: modelsRoot
        )
        loaded[profile.engine] = transcriber
        return transcriber
    }

    public func availability(for profile: SpeechProfile) async -> TranscriberAvailability {
        await transcriber(for: profile).availability()
    }

    public func install(profile: SpeechProfile, progress: @escaping @Sendable (Double) -> Void) async throws {
        let transcriber = transcriber(for: profile)
        try await transcriber.installIfNeeded(progress: progress)
    }

    public func remove(profile: SpeechProfile) async throws {
        let transcriber = transcriber(for: profile)
        try await transcriber.removeInstalledModels()
        loaded[profile.engine] = nil
    }

    public func transcribe(profile: SpeechProfile, audioAt url: URL) async throws -> TranscriptionResult {
        let transcriber = transcriber(for: profile)
        let availability = await transcriber.availability()
        guard availability.isAvailable else {
            throw AppError.speechEngineUnavailable(availability.detail)
        }
        return try await transcriber.transcribe(audioAt: url)
    }
}
