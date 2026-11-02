import Foundation
import Speech
import StudyDomain

/// Apple's on-device speech recognition.
///
/// The request sets `requiresOnDeviceRecognition = true`; if the locale or the
/// installed assets cannot do on-device recognition the engine reports itself
/// unavailable instead of sending audio to a server.
public final class AppleSpeechTranscriber: StudyDomain.SpeechTranscriber, Sendable {
    public let engine: SpeechEngine = .appleOnDevice

    private let languageCode: String?

    public init(languageCode: String? = nil) {
        self.languageCode = languageCode
    }

    private var locale: Locale {
        if let languageCode, !languageCode.isEmpty {
            return Locale(identifier: languageCode)
        }
        return Locale.current
    }

    public func availability() async -> TranscriberAvailability {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .denied || status == .restricted {
            return TranscriberAvailability(
                isAvailable: false,
                requiresDownload: false,
                detail: "Speech recognition permission was denied in System Settings."
            )
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return TranscriberAvailability(isAvailable: false, requiresDownload: false, detail: "No recognizer exists for \(locale.identifier).")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return TranscriberAvailability(
                isAvailable: false,
                requiresDownload: false,
                detail: "On-device recognition is not available for \(locale.identifier) on this Mac. Download the language assets in System Settings, or choose another engine."
            )
        }
        return TranscriberAvailability(
            isAvailable: true,
            requiresDownload: false,
            detail: status == .authorized
                ? "Apple on-device recognition is ready for \(locale.identifier)."
                : "Permission will be requested when you first record."
        )
    }

    public func transcribe(audioAt url: URL) async throws -> TranscriptionResult {
        guard await Self.requestAuthorization() else {
            throw AppError.speechRecognitionPermissionDenied
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AppError.speechEngineUnavailable("Apple speech recognition is not available for \(locale.identifier).")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AppError.speechEngineUnavailable("Apple on-device recognition is not available for \(locale.identifier). Choose another engine; audio is never sent to a server silently.")
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        let box = ContinuationBox()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                box.finish(.success(result.bestTranscription.formattedString))
            } else if let error {
                box.finish(.failure(error))
            }
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            box.finish(.failure(AppError.speechTranscriptionFailed("On-device recognition timed out.")))
        }
        defer {
            timeoutTask.cancel()
            task.cancel()
        }

        let outcome = await box.value()
        switch outcome {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AppError.speechNoAudio }
            return TranscriptionResult(text: trimmed, language: locale.identifier, engine: .appleOnDevice)
        case .failure(let error):
            if let appError = error as? AppError { throw appError }
            throw AppError.speechTranscriptionFailed(error.localizedDescription)
        }
    }

    public static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }
}

/// Bridges a callback that may fire more than once into a single continuation.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<String, Error>, Never>?
    private var result: Result<String, Error>?

    func value() async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ outcome: Result<String, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}
