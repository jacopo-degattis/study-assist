import Foundation
import StudyDomain

#if canImport(FluidAudio)
import FluidAudio
#endif

/// Parakeet models through FluidAudio (Core ML), one model per engine.
///
/// The models are downloaded explicitly, kept in app storage, and loaded lazily.
/// If the model is missing or the machine cannot run it, the engine reports
/// itself unavailable — it never falls back to another provider.
public final class ParakeetSpeechTranscriber: SpeechTranscriber, Sendable {
    public let engine: SpeechEngine
    private let languageCode: String?
    private let modelsRoot: URL

    public init(engine: SpeechEngine, languageCode: String?, modelsRoot: URL) {
        self.engine = engine
        self.languageCode = languageCode
        self.modelsRoot = modelsRoot
    }

    public var modelDirectory: URL {
        modelsRoot.appendingPathComponent("Parakeet-\(engine.rawValue)", isDirectory: true)
    }

    public func availability() async -> TranscriberAvailability {
        #if canImport(FluidAudio) && arch(arm64)
        let available = Self.hasModelFiles(at: modelDirectory, engine: engine)
        if available {
            return TranscriberAvailability(
                isAvailable: true,
                requiresDownload: false,
                detail: "\(engine.displayName) is installed. Transcription stays on this Mac."
            )
        }
        return TranscriberAvailability(
            isAvailable: true,
            requiresDownload: true,
            approximateDownloadMegabytes: Self.approximateDownloadMegabytes(for: engine),
            detail: "Download \(engine.displayName) to transcribe locally. Audio never leaves this Mac."
        )
        #else
        return TranscriberAvailability(
            isAvailable: false,
            requiresDownload: false,
            detail: "\(engine.displayName) requires the FluidAudio runtime on Apple Silicon, which is not part of this build."
        )
        #endif
    }

    public func installIfNeeded(progress: @escaping @Sendable (Double) -> Void) async throws {
        #if canImport(FluidAudio) && arch(arm64)
        let store = ParakeetModelStore.shared
        try await store.load(
            engine: engine,
            directory: modelDirectory,
            languageCode: languageCode,
            progress: progress
        )
        #else
        throw AppError.speechEngineUnavailable("\(engine.displayName) is not available in this build.")
        #endif
    }

    public func transcribe(audioAt url: URL) async throws -> TranscriptionResult {
        #if canImport(FluidAudio) && arch(arm64)
        guard Self.hasModelFiles(at: modelDirectory, engine: engine) else {
            throw AppError.speechModelNotInstalled("Download \(engine.displayName) in Settings before recording.")
        }
        let store = ParakeetModelStore.shared
        if !(await store.isLoaded(engine: engine)) {
            try await store.load(engine: engine, directory: modelDirectory, languageCode: languageCode, progress: { _ in })
        }
        guard let manager = await store.manager(for: engine) else {
            throw AppError.speechModelNotInstalled("Download \(engine.displayName) in Settings first.")
        }

        var audioURL = url
        if url.pathExtension.lowercased() != "wav" {
            audioURL = try AudioFileConverter.convertToPCM(fileAt: url)
        }
        defer {
            if audioURL != url { try? FileManager.default.removeItem(at: audioURL) }
        }

        let language = languageCode.flatMap { Language(rawValue: $0) }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState, language: language)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppError.speechNoAudio }
        return TranscriptionResult(
            text: text,
            language: languageCode,
            engine: engine,
            duration: result.duration
        )
        #else
        throw AppError.speechEngineUnavailable("\(engine.displayName) is not available in this build.")
        #endif
    }

    public func removeInstalledModels() async throws {
        #if canImport(FluidAudio)
        await ParakeetModelStore.shared.unload(engine: engine)
        #endif
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            try FileManager.default.removeItem(at: modelDirectory)
        }
    }

    // MARK: Helpers

    /// Uses FluidAudio's own readiness check: an interrupted download leaves
    /// partial bundles that must not be treated as installed.
    static func hasModelFiles(at directory: URL, engine: SpeechEngine) -> Bool {
        #if canImport(FluidAudio)
        return AsrModels.modelsExist(at: directory, version: parakeetVersion(for: engine))
        #else
        return false
        #endif
    }

    #if canImport(FluidAudio)
    static func parakeetVersion(for engine: SpeechEngine) -> AsrModelVersion {
        switch engine {
        case .parakeetUltra: return .ultra
        case .parakeetTDTv3: return .v3
        case .parakeetTDTv2: return .v2
        case .parakeetTDTCTC110M: return .tdtCtc110m
        case .parakeetJapanese: return .tdtJa
        default: return .v3
        }
    }
    #endif

    static func approximateDownloadMegabytes(for engine: SpeechEngine) -> Int? {
        switch engine {
        case .parakeetUltra: return 620
        case .parakeetTDTv3: return 470
        case .parakeetTDTv2: return 450
        case .parakeetTDTCTC110M: return 120
        case .parakeetJapanese: return 620
        default: return nil
        }
    }
}

#if canImport(FluidAudio) && arch(arm64)

/// Serializes model downloads and keeps at most one Parakeet model loaded.
actor ParakeetModelStore {
    static let shared = ParakeetModelStore()

    private var managers: [SpeechEngine: AsrManager] = [:]

    func isLoaded(engine: SpeechEngine) -> Bool {
        managers[engine] != nil
    }

    func manager(for engine: SpeechEngine) -> AsrManager? {
        managers[engine]
    }

    func load(
        engine: SpeechEngine,
        directory: URL,
        languageCode: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if managers[engine] != nil { return }
        // Only one model resident at a time keeps memory predictable.
        for other in Array(managers.keys) {
            await managers[other]?.cleanup()
            managers[other] = nil
        }

        let version = ParakeetSpeechTranscriber.parakeetVersion(for: engine)
        do {
            let models = try await AsrModels.downloadAndLoad(
                to: directory,
                version: version,
                progressHandler: { downloadProgress in
                    progress(min(max(downloadProgress.fractionCompleted, 0), 1))
                }
            )
            let manager = AsrManager(config: .default, models: models)
            managers[engine] = manager
            progress(1.0)
        } catch {
            throw AppError.speechModelDownloadFailed(error.localizedDescription)
        }
    }

    func unload(engine: SpeechEngine) async {
        await managers[engine]?.cleanup()
        managers[engine] = nil
    }

    static func version(for engine: SpeechEngine) -> AsrModelVersion {
        switch engine {
        case .parakeetUltra: return .ultra
        case .parakeetTDTv3: return .v3
        case .parakeetTDTv2: return .v2
        case .parakeetTDTCTC110M: return .tdtCtc110m
        case .parakeetJapanese: return .tdtJa
        default: return .v3
        }
    }
}

#endif
