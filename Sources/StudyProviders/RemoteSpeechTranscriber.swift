import Foundation
import StudyDomain

/// Uploads a recorded answer to a user-configured audio transcription endpoint.
///
/// This is deliberately separate from the LLM profile: a chat endpoint is not an
/// audio endpoint, so the URL, model and key are its own settings.
public struct RemoteSpeechTranscriber: SpeechTranscriber {
    public let engine: SpeechEngine = .customEndpoint

    private let profile: SpeechProfile
    private let apiKey: String?
    private let transport: any HTTPTransport

    public init(
        profile: SpeechProfile,
        apiKey: String?,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.profile = profile
        self.apiKey = apiKey
        self.transport = transport
    }

    public func availability() async -> TranscriberAvailability {
        guard let baseURL = profile.remoteBaseURL, !baseURL.isEmpty else {
            return TranscriberAvailability(isAvailable: false, requiresDownload: false, detail: "Set the transcription endpoint URL in Settings.")
        }
        do {
            _ = try ProviderEndpoint.transcriptionEndpointURL(baseURL: baseURL)
        } catch let error as AppError {
            return TranscriberAvailability(isAvailable: false, requiresDownload: false, detail: error.userMessage)
        } catch {
            return TranscriberAvailability(isAvailable: false, requiresDownload: false, detail: error.localizedDescription)
        }
        return TranscriberAvailability(isAvailable: true, requiresDownload: false, detail: "Audio is sent to this endpoint for transcription.")
    }

    public func transcribe(audioAt url: URL) async throws -> TranscriptionResult {
        guard let baseURL = profile.remoteBaseURL, !baseURL.isEmpty else {
            throw AppError.speechEngineUnavailable("No transcription endpoint is configured.")
        }
        let endpoint = try ProviderEndpoint.transcriptionEndpointURL(baseURL: baseURL)
        guard let audioData = try? Data(contentsOf: url), !audioData.isEmpty else {
            throw AppError.speechNoAudio
        }
        guard audioData.count <= 40 * 1024 * 1024 else {
            throw AppError.speechTranscriptionFailed("The recording is too large for the endpoint.")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            audio: audioData,
            fileName: url.lastPathComponent,
            mimeType: Self.mimeType(for: url),
            model: profile.modelId,
            language: profile.language
        )

        let response = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw ProviderErrorMapping.httpError(status: response.statusCode, headers: response.headers, body: response.data)
        }
        guard let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw AppError.speechTranscriptionFailed("The endpoint returned a response that was not JSON.")
        }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            throw AppError.speechTranscriptionFailed(ProviderErrorMapping.sanitize(message))
        }
        guard let text = root["text"] as? String else {
            throw AppError.speechTranscriptionFailed("The endpoint returned no transcript.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.speechNoAudio
        }
        return TranscriptionResult(text: trimmed, language: profile.language, engine: .customEndpoint)
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "m4a", "mp4": return "audio/mp4"
        case "caf": return "audio/x-caf"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }

    static func multipartBody(
        boundary: String,
        audio: Data,
        fileName: String,
        mimeType: String,
        model: String?,
        language: String?
    ) -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        if let model, !model.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
            append("\(model)\r\n")
        }
        if let language, !language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}
