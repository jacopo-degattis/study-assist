import Foundation

/// Every user-facing failure in the app is one of these. Each carries a message
/// that is safe to show: no credentials, request bodies, or document text.
public enum AppError: Error, Sendable, Equatable {
    // Documents
    case documentUnsupportedType(String)
    case documentUnreadable(String)
    case documentEmpty(String)
    case documentImportFailed(String)
    case documentInsufficientText(String)
    case documentTooLarge(String)
    case documentCorruptArchive(String)
    case documentNoActiveSnapshot

    // Providers
    case providerNotConfigured
    case providerInvalidURL(String)
    case providerInsecureURL(String)
    case providerUnauthorized(String)
    case providerForbidden(String)
    case providerNotFound(String)
    case providerRateLimited(retryAfter: TimeInterval?)
    case providerTimeout
    case providerServerError(status: Int)
    case providerMalformedResponse(String)
    case providerHTTPError(status: Int, message: String)
    case providerCancelled
    case providerOffline

    // Model output validation
    case validationFailed(String)
    case insufficientEvidence(String)
    case questionRejected(String)
    case evaluationRejected(String)

    // Speech
    case microphonePermissionDenied
    case speechRecognitionPermissionDenied
    case speechEngineUnavailable(String)
    case speechModelNotInstalled(String)
    case speechModelDownloadFailed(String)
    case speechTranscriptionFailed(String)
    case speechNoAudio

    // Persistence / state
    case persistenceFailure(String)
    case invalidStateTransition(String)
    case operationCancelled

    /// A short, understandable message for the user.
    public var userMessage: String {
        switch self {
        case .documentUnsupportedType(let detail):
            return "That file type is not supported. Choose a PDF or DOCX document. \(detail)"
        case .documentUnreadable(let detail):
            return "The document could not be read. \(detail)"
        case .documentEmpty(let detail):
            return "The document has no readable text. \(detail)"
        case .documentImportFailed(let detail):
            return "Import failed. \(detail)"
        case .documentInsufficientText(let detail):
            return "There is not enough reliable text to study from this document. \(detail)"
        case .documentTooLarge(let detail):
            return "The document is too large to import safely. \(detail)"
        case .documentCorruptArchive(let detail):
            return "The DOCX package is malformed or unsafe. \(detail)"
        case .documentNoActiveSnapshot:
            return "This document has no prepared version. Import it again."
        case .providerNotConfigured:
            return "Configure an AI model in Settings before studying."
        case .providerInvalidURL(let detail):
            return "The provider URL is not valid. \(detail)"
        case .providerInsecureURL(let detail):
            return "Remote providers must use HTTPS. \(detail)"
        case .providerUnauthorized(let detail):
            return "The provider rejected the API key (401). \(detail)"
        case .providerForbidden(let detail):
            return "The provider refused access (403). \(detail)"
        case .providerNotFound(let detail):
            return "The endpoint or model was not found (404). \(detail)"
        case .providerRateLimited(let retryAfter):
            if let retryAfter {
                return "The provider is rate limiting requests. Try again in about \(Int(retryAfter.rounded())) seconds."
            }
            return "The provider is rate limiting requests. Try again shortly."
        case .providerTimeout:
            return "The provider did not respond in time. Try again."
        case .providerServerError(let status):
            return "The provider had an internal error (\(status)). Try again later."
        case .providerMalformedResponse(let detail):
            return "The provider returned a response the app could not understand. \(detail)"
        case .providerHTTPError(let status, let message):
            return "The provider returned HTTP \(status). \(message)"
        case .providerCancelled:
            return "The request was cancelled."
        case .providerOffline:
            return "No network connection is available for this provider."
        case .validationFailed(let detail):
            return "The model response did not pass validation. \(detail)"
        case .insufficientEvidence(let detail):
            return "There is not enough source evidence for this step. \(detail)"
        case .questionRejected(let detail):
            return "The generated question was discarded because its source support could not be verified. \(detail)"
        case .evaluationRejected(let detail):
            return "This answer could not be graded reliably. \(detail)"
        case .microphonePermissionDenied:
            return "Microphone access is needed to record an answer. You can allow it in System Settings › Privacy & Security › Microphone."
        case .speechRecognitionPermissionDenied:
            return "Speech recognition permission is needed for on-device transcription."
        case .speechEngineUnavailable(let detail):
            return "This speech engine is not available on this Mac. \(detail)"
        case .speechModelNotInstalled(let detail):
            return "Download the speech model before recording. \(detail)"
        case .speechModelDownloadFailed(let detail):
            return "The speech model could not be downloaded. \(detail)"
        case .speechTranscriptionFailed(let detail):
            return "Transcription failed. \(detail)"
        case .speechNoAudio:
            return "No speech was detected in the recording."
        case .persistenceFailure(let detail):
            return "Local storage failed. \(detail)"
        case .invalidStateTransition(let detail):
            return "That action is not available right now. \(detail)"
        case .operationCancelled:
            return "The operation was cancelled."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .providerTimeout, .providerRateLimited, .providerServerError, .providerOffline:
            return true
        default:
            return false
        }
    }
}

extension AppError: LocalizedError {
    public var errorDescription: String? { userMessage }
}
