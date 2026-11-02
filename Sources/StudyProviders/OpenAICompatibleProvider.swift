import Foundation
import StudyDomain

/// Adapter for OpenAI-compatible Chat Completions and Responses endpoints.
///
/// This type handles transport, authentication, timeouts, bounded retries,
/// response-format fallback and decoding. It contains no pedagogical policy.
public struct OpenAICompatibleProvider: LLMProvider {
    public let profile: ProviderProfile
    private let apiKey: String?
    private let transport: any HTTPTransport

    public init(profile: ProviderProfile, apiKey: String?, transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.profile = profile
        self.apiKey = apiKey
        self.transport = transport
    }

    // MARK: LLMProvider

    public func complete(_ request: LLMRequest) async throws -> LLMCompletion {
        let formats = Self.fallbackFormats(for: request.responseFormat)
        var lastFormatError: AppError?

        for format in formats {
            do {
                let (text, latency) = try await perform(request, format: format)
                return LLMCompletion(
                    text: text,
                    modelId: profile.modelId,
                    providerProfileId: profile.id,
                    latency: latency,
                    responseFormatUsed: format
                )
            } catch let error as AppError {
                if Self.isFormatRejection(error) {
                    lastFormatError = error
                    continue
                }
                throw error
            }
        }
        throw lastFormatError ?? AppError.providerMalformedResponse("The provider accepted none of the supported response formats.")
    }

    public func testConnection() async throws -> ConnectionTestResult {
        // Validates URL and HTTPS policy before any network activity.
        _ = try ProviderEndpoint.endpointURL(baseURL: profile.baseURL, style: profile.apiStyle)
        if profile.requiresAuthentication, (apiKey ?? "").isEmpty {
            throw AppError.providerNotConfigured
        }

        let start = Date()
        let probeConversationID = "studyapp-connection-test-\(profile.id.rawValue)"
        let probe = LLMRequest(
            system: "You are a connectivity probe for a study application.",
            user: "Reply with exactly: ok",
            responseFormat: .text,
            temperature: 0,
            maxOutputTokens: 16,
            conversationID: probeConversationID
        )
        let completion = try await complete(probe)
        guard !completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.providerMalformedResponse("The model returned an empty message.")
        }

        var structuredSupported = false
        var detail = "Authentication, endpoint and model verified."
        do {
            let jsonProbe = LLMRequest(
                system: "Reply only with a JSON object and no other text.",
                user: "Return exactly {\"ok\": true}",
                responseFormat: .jsonObject,
                temperature: 0,
                maxOutputTokens: 64,
                conversationID: probeConversationID
            )
            let jsonCompletion = try await complete(jsonProbe)
            structuredSupported = JSONExtraction.objectData(from: jsonCompletion.text) != nil
            if !structuredSupported {
                detail += " The model accepted JSON mode but returned unparseable JSON; the app will rely on local validation."
            } else {
                detail += " Structured JSON output verified."
            }
        } catch {
            detail += " Structured JSON output is not available: \(Self.shortMessage(error))."
        }

        return ConnectionTestResult(
            modelId: profile.modelId,
            latency: Date().timeIntervalSince(start),
            responseFormatSupported: structuredSupported,
            detail: detail
        )
    }

    // MARK: Transport

    private func perform(_ request: LLMRequest, format: LLMResponseFormat) async throws -> (String, TimeInterval) {
        let httpRequest = try makeHTTPRequest(request, format: format)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let start = Date()
            do {
                let response = try await transport.send(httpRequest)
                guard (200...299).contains(response.statusCode) else {
                    throw ProviderErrorMapping.httpError(status: response.statusCode, headers: response.headers, body: response.data)
                }
                let text = try Self.extractText(from: response.data, style: profile.apiStyle)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppError.providerMalformedResponse("The model returned an empty message.")
                }
                return (text, Date().timeIntervalSince(start))
            } catch let error as AppError {
                if error.isRetryable,
                   attempt < max(0, profile.maxRetries),
                   let delay = Self.retryDelay(for: error, attempt: attempt) {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            } catch let error as URLError {
                let mapped = ProviderErrorMapping.map(error)
                if mapped.isRetryable, attempt < max(0, profile.maxRetries) {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(0.6 * pow(2, Double(attempt)) * 1_000_000_000))
                    continue
                }
                throw mapped
            }
        }
    }

    private func makeHTTPRequest(_ request: LLMRequest, format: LLMResponseFormat) throws -> URLRequest {
        let url = try ProviderEndpoint.endpointURL(baseURL: profile.baseURL, style: profile.apiStyle)
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.timeoutInterval = max(5, profile.timeoutSeconds)
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        httpRequest.setValue(ProviderEndpoint.clientUserAgent, forHTTPHeaderField: "User-Agent")

        if let apiKey, !apiKey.isEmpty {
            httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // OpenCode Go requires a stable session id per conversation for routing
        // and prompt caching. Send it only to OpenCode, and only if the user has
        // not supplied their own header.
        let userSuppliedSessionHeader = profile.extraHeaders.keys.contains { $0.lowercased() == "x-opencode-session" }
        if ProviderEndpoint.isOpenCodeHost(url.host),
           !userSuppliedSessionHeader,
           let conversationID = request.conversationID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !conversationID.isEmpty {
            httpRequest.setValue(conversationID, forHTTPHeaderField: "x-opencode-session")
        }

        // Extra headers are non-secret by design; Authorization always comes from the Keychain.
        for (name, value) in profile.extraHeaders where name.lowercased() != "authorization" {
            httpRequest.setValue(value, forHTTPHeaderField: name)
        }

        let body = try Self.makeBody(profile: profile, request: request, format: format)
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return httpRequest
    }

    static func makeBody(profile: ProviderProfile, request: LLMRequest, format: LLMResponseFormat) throws -> [String: Any] {
        switch profile.apiStyle {
        case .chatCompletions:
            var body: [String: Any] = [
                "model": profile.modelId,
                "messages": [
                    ["role": "system", "content": request.system],
                    ["role": "user", "content": request.user],
                ],
                "temperature": request.temperature,
                "stream": false,
            ]
            if let maxTokens = request.maxOutputTokens {
                body["max_tokens"] = maxTokens
            }
            switch format {
            case .text:
                break
            case .jsonObject:
                body["response_format"] = ["type": "json_object"]
            case let .jsonSchema(name, schemaJSON):
                if let schema = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) as? [String: Any] {
                    body["response_format"] = [
                        "type": "json_schema",
                        "json_schema": ["name": name, "strict": true, "schema": schema],
                    ]
                } else {
                    body["response_format"] = ["type": "json_object"]
                }
            }
            return body

        case .responses:
            var body: [String: Any] = [
                "model": profile.modelId,
                "instructions": request.system,
                "input": request.user,
                "temperature": request.temperature,
            ]
            if let maxTokens = request.maxOutputTokens {
                body["max_output_tokens"] = maxTokens
            }
            switch format {
            case .text:
                break
            case .jsonObject:
                body["text"] = ["format": ["type": "json_object"]]
            case let .jsonSchema(name, schemaJSON):
                if let schema = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) as? [String: Any] {
                    body["text"] = [
                        "format": ["type": "json_schema", "name": name, "strict": true, "schema": schema],
                    ]
                } else {
                    body["text"] = ["format": ["type": "json_object"]]
                }
            }
            return body
        }
    }

    static func extractText(from data: Data, style: ProviderAPIStyle) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.providerMalformedResponse("The response body was not JSON.")
        }
        if let error = root["error"] {
            let message: String
            if let dictionary = error as? [String: Any], let text = dictionary["message"] as? String {
                message = ProviderErrorMapping.sanitize(text)
            } else if let text = error as? String {
                message = ProviderErrorMapping.sanitize(text)
            } else {
                message = "The provider reported an error."
            }
            throw AppError.providerHTTPError(status: 200, message: message)
        }

        switch style {
        case .chatCompletions:
            guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else {
                throw AppError.providerMalformedResponse("The response contained no choices.")
            }
            if let message = first["message"] as? [String: Any] {
                if let content = message["content"] as? String {
                    return content
                }
                if let parts = message["content"] as? [[String: Any]] {
                    let texts = parts.compactMap { $0["text"] as? String }
                    if !texts.isEmpty { return texts.joined() }
                }
                if let refusal = message["refusal"] as? String {
                    throw AppError.providerHTTPError(status: 200, message: ProviderErrorMapping.sanitize(refusal))
                }
            }
            if let text = first["text"] as? String { return text }
            throw AppError.providerMalformedResponse("The response message had no text content.")

        case .responses:
            if let outputText = root["output_text"] as? String, !outputText.isEmpty {
                return outputText
            }
            if let output = root["output"] as? [[String: Any]] {
                var texts: [String] = []
                for item in output {
                    if let content = item["content"] as? [[String: Any]] {
                        for part in content {
                            if let text = part["text"] as? String, part["type"] as? String != "reasoning_text" {
                                texts.append(text)
                            }
                        }
                    }
                }
                if !texts.isEmpty { return texts.joined() }
            }
            throw AppError.providerMalformedResponse("The response contained no output text.")
        }
    }

    // MARK: Fallback and retry policy

    static func fallbackFormats(for format: LLMResponseFormat) -> [LLMResponseFormat] {
        switch format {
        case .text:
            return [.text]
        case .jsonObject:
            return [.jsonObject, .text]
        case .jsonSchema:
            return [format, .jsonObject, .text]
        }
    }

    static func isFormatRejection(_ error: AppError) -> Bool {
        switch error {
        case let .providerHTTPError(status, message):
            guard status == 400 || status == 422 || status == 500 else { return false }
            let lowered = message.lowercased()
            let markers = ["response_format", "json_schema", "json schema", "structured output", "text.format", "unsupported parameter", "not supported"]
            return markers.contains { lowered.contains($0) }
        default:
            return false
        }
    }

    static func retryDelay(for error: AppError, attempt: Int) -> TimeInterval? {
        switch error {
        case .providerRateLimited(let retryAfter):
            if let retryAfter, retryAfter <= 10 { return max(0.5, retryAfter) }
            return nil
        case .providerTimeout, .providerOffline, .providerServerError:
            return min(5, 0.6 * pow(2, Double(attempt)))
        default:
            return nil
        }
    }

    static func shortMessage(_ error: Error) -> String {
        if let appError = error as? AppError {
            return appError.userMessage
        }
        return error.localizedDescription
    }
}

// MARK: - Credentials and factory

public enum ProviderCredentials {
    public static func reference(for id: ProviderProfileID) -> String {
        "provider-\(id.rawValue)"
    }

    public static func speechReference(for id: SpeechProfileID) -> String {
        "speech-\(id.rawValue)"
    }

    /// Stores (or clears) the key and keeps only its reference on the profile.
    public static func applyAPIKey(
        _ key: String?,
        to profile: inout ProviderProfile,
        secretStore: any SecretStore
    ) throws {
        let reference = profile.keychainRef ?? reference(for: profile.id)
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            try? secretStore.deleteSecret(for: reference)
            profile.keychainRef = nil
            return
        }
        try secretStore.store(secret: trimmed, for: reference)
        profile.keychainRef = reference
    }

    public static func apiKey(for profile: ProviderProfile, secretStore: any SecretStore) throws -> String? {
        guard let reference = profile.keychainRef else { return nil }
        return try secretStore.secret(for: reference)
    }

    public static func removeAPIKey(for profile: ProviderProfile, secretStore: any SecretStore) {
        guard let reference = profile.keychainRef else { return }
        try? secretStore.deleteSecret(for: reference)
    }
}

public enum LLMProviderFactory {
    public static func makeProvider(
        profile: ProviderProfile,
        secretStore: any SecretStore,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) throws -> any LLMProvider {
        let key = try ProviderCredentials.apiKey(for: profile, secretStore: secretStore)
        if profile.requiresAuthentication, (key ?? "").isEmpty {
            throw AppError.providerNotConfigured
        }
        return OpenAICompatibleProvider(profile: profile, apiKey: key, transport: transport)
    }
}
