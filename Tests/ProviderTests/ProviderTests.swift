import XCTest
import Foundation
@testable import StudyProviders
import StudyDomain

final class ProviderTests: XCTestCase {

    // MARK: URL policy

    func testRemoteHTTPSIsAcceptedAndLoopbackHTTPIsScoped() throws {
        XCTAssertNoThrow(try ProviderEndpoint.validateBaseURL("https://openrouter.ai/api/v1"))
        XCTAssertNoThrow(try ProviderEndpoint.validateBaseURL("http://localhost:8000/v1"))
        XCTAssertNoThrow(try ProviderEndpoint.validateBaseURL("http://127.0.0.1:1234/v1"))

        XCTAssertThrowsError(try ProviderEndpoint.validateBaseURL("http://example.com/v1")) { error in
            guard case AppError.providerInsecureURL = error else { return XCTFail("Unexpected: \(error)") }
        }
        XCTAssertThrowsError(try ProviderEndpoint.validateBaseURL("ftp://example.com/v1"))
        XCTAssertThrowsError(try ProviderEndpoint.validateBaseURL("not a url"))
        XCTAssertThrowsError(try ProviderEndpoint.validateBaseURL("https://user:pass@example.com/v1"))
        XCTAssertThrowsError(try ProviderEndpoint.validateBaseURL(""))
    }

    func testEndpointResolutionAcceptsBaseOrFullURLs() throws {
        let chat = try ProviderEndpoint.endpointURL(baseURL: "https://openrouter.ai/api/v1", style: .chatCompletions)
        XCTAssertEqual(chat.absoluteString, "https://openrouter.ai/api/v1/chat/completions")

        let responses = try ProviderEndpoint.endpointURL(baseURL: "https://api.openai.com/v1", style: .responses)
        XCTAssertEqual(responses.absoluteString, "https://api.openai.com/v1/responses")

        let fullChat = try ProviderEndpoint.endpointURL(baseURL: "https://host/v1/chat/completions", style: .chatCompletions)
        XCTAssertEqual(fullChat.absoluteString, "https://host/v1/chat/completions")

        let switched = try ProviderEndpoint.endpointURL(baseURL: "https://host/v1/chat/completions", style: .responses)
        XCTAssertEqual(switched.absoluteString, "https://host/v1/responses")

        let stt = try ProviderEndpoint.transcriptionEndpointURL(baseURL: "http://localhost:9000/v1")
        XCTAssertEqual(stt.absoluteString, "http://localhost:9000/v1/audio/transcriptions")
    }

    func testOpenCodeGoEndpointResolution() throws {
        let base = "https://opencode.ai/inference/go/openai/v1"
        let chat = try ProviderEndpoint.endpointURL(baseURL: base, style: .chatCompletions)
        XCTAssertEqual(chat.absoluteString, base + "/chat/completions")
        let responses = try ProviderEndpoint.endpointURL(baseURL: base, style: .responses)
        XCTAssertEqual(responses.absoluteString, base + "/responses")
        XCTAssertTrue(ProviderEndpoint.isOpenCodeHost("opencode.ai"))
        XCTAssertTrue(ProviderEndpoint.isOpenCodeHost("api.opencode.ai"))
        XCTAssertFalse(ProviderEndpoint.isOpenCodeHost("example.test"))
    }

    // MARK: Chat Completions

    func testChatCompletionRequestAndResponse() async throws {
        let transport = MockHTTPTransport(responses: [
            .json(200, #"{"choices":[{"message":{"role":"assistant","content":"{\"ok\":true}"},"finish_reason":"stop"}]}"#)
        ])
        let provider = OpenAICompatibleProvider(profile: makeProfile(), apiKey: "sk-secret", transport: transport)
        let request = LLMRequest(
            system: "system",
            user: "user",
            responseFormat: .jsonSchema(name: "answer", schemaJSON: #"{"type":"object"}"#),
            temperature: 0,
            maxOutputTokens: 100
        )
        let completion = try await provider.complete(request)
        XCTAssertEqual(completion.text, #"{"ok":true}"#)
        XCTAssertEqual(completion.responseFormatUsed, .jsonSchema(name: "answer", schemaJSON: #"{"type":"object"}"#))

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://example.test/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer sk-secret")
        let body = try XCTUnwrap(sent.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "test-model")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        let format = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        // The secret never appears in a way the app logs; here we only check the header.
        XCTAssertFalse(String(data: body, encoding: .utf8)?.contains("sk-secret") ?? true)
    }

    func testResponsesAPIParsing() async throws {
        let transport = MockHTTPTransport(responses: [
            .json(200, #"{"output":[{"type":"message","content":[{"type":"output_text","text":"hello "},{"type":"output_text","text":"world"}]}]}"#)
        ])
        var profile = makeProfile()
        profile.apiStyle = .responses
        let provider = OpenAICompatibleProvider(profile: profile, apiKey: "k", transport: transport)
        let completion = try await provider.complete(LLMRequest(system: "s", user: "u"))
        XCTAssertEqual(completion.text, "hello world")
        let sent = try XCTUnwrap(transport.requests.first)
        let body = try XCTUnwrap(sent.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["instructions"] as? String, "s")
        XCTAssertEqual(json["input"] as? String, "u")
    }

    // MARK: Errors and retries

    func testAuthenticationAndRateLimitErrorsAreUnderstandable() async throws {
        let unauthorized = OpenAICompatibleProvider(
            profile: makeProfile(),
            apiKey: "bad",
            transport: MockHTTPTransport(responses: [.json(401, #"{"error":{"message":"Invalid API key"}}"#)])
        )
        do {
            _ = try await unauthorized.complete(LLMRequest(system: "s", user: "u"))
            XCTFail("Expected 401")
        } catch let error as AppError {
            guard case AppError.providerUnauthorized(let message) = error else {
                return XCTFail("Unexpected: \(error)")
            }
            XCTAssertTrue(message.contains("Invalid API key"))
            XCTAssertTrue(error.userMessage.contains("401"))
        }

        let limited = OpenAICompatibleProvider(
            profile: makeProfile(),
            apiKey: "k",
            transport: MockHTTPTransport(responses: [
                .response(HTTPResponse(data: Data(#"{"error":{"message":"slow down"}}"#.utf8), statusCode: 429, headers: ["retry-after": "3"]))
            ])
        )
        do {
            _ = try await limited.complete(LLMRequest(system: "s", user: "u"))
            XCTFail("Expected 429")
        } catch let error as AppError {
            guard case AppError.providerRateLimited(let retryAfter) = error else {
                return XCTFail("Unexpected: \(error)")
            }
            XCTAssertEqual(retryAfter, 3)
        }
    }

    func testServerErrorIsRetriedOnceWhenConfigured() async throws {
        var profile = makeProfile()
        profile.maxRetries = 1
        let transport = MockHTTPTransport(responses: [
            .json(500, #"{"error":{"message":"boom"}}"#),
            .json(200, #"{"choices":[{"message":{"content":"recovered"}}]}"#),
        ])
        let provider = OpenAICompatibleProvider(profile: profile, apiKey: "k", transport: transport)
        let completion = try await provider.complete(LLMRequest(system: "s", user: "u"))
        XCTAssertEqual(completion.text, "recovered")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testNoRetryOnAuthenticationFailure() async throws {
        var profile = makeProfile()
        profile.maxRetries = 3
        let transport = MockHTTPTransport(responses: [.json(401, #"{"error":{"message":"no"}}"#)])
        let provider = OpenAICompatibleProvider(profile: profile, apiKey: "k", transport: transport)
        _ = try? await provider.complete(LLMRequest(system: "s", user: "u"))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testStructuredFormatFallsBackButNeverChangesProviderOrModel() async throws {
        var profile = makeProfile()
        profile.maxRetries = 0
        let transport = MockHTTPTransport(responses: [
            .json(400, #"{"error":{"message":"response_format json_schema is not supported"}}"#),
            .json(200, #"{"choices":[{"message":{"content":"{\"ok\":true}"}}]}"#),
        ])
        let provider = OpenAICompatibleProvider(profile: profile, apiKey: "k", transport: transport)
        let schema = #"{"type":"object"}"#
        let completion = try await provider.complete(
            LLMRequest(system: "s", user: "u", responseFormat: .jsonSchema(name: "x", schemaJSON: schema))
        )
        XCTAssertEqual(completion.responseFormatUsed, .jsonObject)
        XCTAssertEqual(completion.modelId, profile.modelId)
        XCTAssertEqual(completion.providerProfileId, profile.id)
        XCTAssertEqual(transport.requests.count, 2)
        let secondBody = try XCTUnwrap(transport.requests.last?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        let format = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_object")
    }

    func testEmptyAndMalformedResponsesAreRejected() async throws {
        let empty = OpenAICompatibleProvider(
            profile: makeProfile(),
            apiKey: "k",
            transport: MockHTTPTransport(responses: [.json(200, #"{"choices":[{"message":{"content":""}}]}"#)])
        )
        do {
            _ = try await empty.complete(LLMRequest(system: "s", user: "u"))
            XCTFail("Expected empty response rejection")
        } catch let error as AppError {
            guard case .providerMalformedResponse = error else { return XCTFail("Unexpected: \(error)") }
        }

        let notJSON = OpenAICompatibleProvider(
            profile: makeProfile(),
            apiKey: "k",
            transport: MockHTTPTransport(responses: [.raw(200, Data("not json".utf8))])
        )
        do {
            _ = try await notJSON.complete(LLMRequest(system: "s", user: "u"))
            XCTFail("Expected malformed response rejection")
        } catch let error as AppError {
            guard case .providerMalformedResponse = error else { return XCTFail("Unexpected: \(error)") }
        }
    }

    func testJSONExtractionAcceptsFencesAndProse() {
        let fenced = "```json\n{\"a\": 1}\n```"
        XCTAssertNotNil(JSONExtraction.objectData(from: fenced))
        let prose = "Here is the object: {\"a\": 1} — done"
        XCTAssertNotNil(JSONExtraction.objectData(from: prose))
        XCTAssertNil(JSONExtraction.objectData(from: "no object here"))
        XCTAssertNil(JSONExtraction.objectData(from: "[1,2,3]"))
    }

    func testFallbackWhenResponseFormatCompletelyUnsupported() async throws {
        var profile = makeProfile()
        profile.maxRetries = 0
        // Server rejects all response_format attempts, then accepts plain text
        let transport = MockHTTPTransport(responses: [
            .json(400, #"{"error":{"message":"The parameter 'response_format' is not supported"}}"#),
            .json(400, #"{"error":{"message":"The parameter 'response_format' is not supported"}}"#),
            .json(200, #"{"choices":[{"message":{"content":"{\"ok\":true}"}}]}"#),
        ])
        let provider = OpenAICompatibleProvider(profile: profile, apiKey: "k", transport: transport)
        let schema = #"{"type":"object"}"#
        let completion = try await provider.complete(
            LLMRequest(system: "s", user: "u", responseFormat: .jsonSchema(name: "x", schemaJSON: schema))
        )
        XCTAssertEqual(completion.responseFormatUsed, .text)
        XCTAssertEqual(transport.requests.count, 3)
        // The final request should NOT have response_format in the body
        let lastBody = try XCTUnwrap(transport.requests.last?.httpBody)
        let lastJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: lastBody) as? [String: Any])
        XCTAssertNil(lastJSON["response_format"], "Final fallback request must not send response_format")
    }

    // MARK: Connection test

    func testOpenCodeRequestsCarrySessionAndHonestUserAgent() async throws {
        var profile = makeProfile()
        profile.baseURL = "https://opencode.ai/inference/go/openai/v1"
        profile.apiStyle = .responses
        profile.modelId = "gpt-5.6-luna"
        let transport = MockHTTPTransport(responses: [
            .json(200, #"{"output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#)
        ])
        let provider = OpenAICompatibleProvider(profile: profile, apiKey: "oc_sk_test", transport: transport)
        let sessionID = "4b0c1f0e-2f6a-4c1e-9d3a-111111111111"
        _ = try await provider.complete(LLMRequest(system: "s", user: "u", conversationID: sessionID))

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://opencode.ai/inference/go/openai/v1/responses")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-opencode-session"), sessionID)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer oc_sk_test")
        let userAgent = try XCTUnwrap(sent.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertTrue(userAgent.contains("StudyApp/"))
        XCTAssertFalse(userAgent.lowercased().contains("opencode"), "The app must not impersonate the OpenCode client")
    }

    func testSessionHeaderIsScopedToOpenCodeHosts() async throws {
        var profile = makeProfile()
        profile.baseURL = "https://api.other-provider.test/v1"
        let transport = MockHTTPTransport(responses: [
            .json(200, #"{"choices":[{"message":{"content":"ok"}}]}"#)
        ])
        let provider = OpenAICompatibleProvider(profile: profile, apiKey: "k", transport: transport)
        _ = try await provider.complete(LLMRequest(system: "s", user: "u", conversationID: "session-123"))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertNil(sent.value(forHTTPHeaderField: "x-opencode-session"), "Session ids must not leak to other providers")
    }

    func testUserSuppliedOpenCodeSessionHeaderWins() async throws {
        var profile = makeProfile()
        profile.baseURL = "https://opencode.ai/inference/go/openai/v1"
        profile.extraHeaders = ["x-opencode-session": "explicit-session"]
        let transport = MockHTTPTransport(responses: [
            .json(200, #"{"choices":[{"message":{"content":"ok"}}]}"#)
        ])
        let provider = OpenAICompatibleProvider(profile: profile, apiKey: "k", transport: transport)
        _ = try await provider.complete(LLMRequest(system: "s", user: "u", conversationID: "generated-session"))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-opencode-session"), "explicit-session")
    }

    func testOpenCodeConnectionTestSendsASessionHeader() async throws {
        var profile = makeProfile()
        profile.baseURL = "https://opencode.ai/inference/go/openai/v1"
        let transport = MockHTTPTransport(responses: [
            .json(200, #"{"choices":[{"message":{"content":"ok"}}]}"#),
            .json(200, #"{"choices":[{"message":{"content":"{\"ok\":true}"}}]}"#),
        ])
        let provider = OpenAICompatibleProvider(profile: profile, apiKey: "k", transport: transport)
        let result = try await provider.testConnection()
        XCTAssertTrue(result.responseFormatSupported)
        let first = try XCTUnwrap(transport.requests.first)
        let session = try XCTUnwrap(first.value(forHTTPHeaderField: "x-opencode-session"))
        XCTAssertTrue(session.hasPrefix("studyapp-connection-test-"))
    }

    func testConnectionTestVerifiesTextAndStructuredOutput() async throws {
        let transport = MockHTTPTransport(responses: [
            .json(200, #"{"choices":[{"message":{"content":"ok"}}]}"#),
            .json(200, #"{"choices":[{"message":{"content":"{\"ok\":true}"}}]}"#),
        ])
        let provider = OpenAICompatibleProvider(profile: makeProfile(), apiKey: "k", transport: transport)
        let result = try await provider.testConnection()
        XCTAssertTrue(result.responseFormatSupported)
        XCTAssertEqual(result.modelId, "test-model")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testConnectionTestFailsWithoutAKeyWhenAuthenticationIsRequired() async throws {
        let provider = OpenAICompatibleProvider(profile: makeProfile(), apiKey: nil, transport: MockHTTPTransport(responses: []))
        do {
            _ = try await provider.testConnection()
            XCTFail("Expected providerNotConfigured")
        } catch let error as AppError {
            XCTAssertEqual(error, .providerNotConfigured)
        }
    }

    // MARK: Remote speech

    func testRemoteSpeechUploadsMultipartAndReturnsTranscript() async throws {
        let transport = MockHTTPTransport(responses: [.json(200, #"{"text":"  the membrane potential  "}"#)])
        let profile = SpeechProfile(
            engine: .customEndpoint,
            modelId: "whisper-1",
            language: "en",
            remoteBaseURL: "https://stt.example.com/v1"
        )
        let transcriber = RemoteSpeechTranscriber(profile: profile, apiKey: "stt-key", transport: transport)
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data(repeating: 0x41, count: 2_048).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let result = try await transcriber.transcribe(audioAt: audioURL)
        XCTAssertEqual(result.text, "the membrane potential")
        XCTAssertEqual(result.engine, .customEndpoint)

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://stt.example.com/v1/audio/transcriptions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer stt-key")
        let body = try XCTUnwrap(sent.httpBody)
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("name=\"file\""))
        XCTAssertTrue(bodyString.contains("name=\"model\""))
        XCTAssertTrue(bodyString.contains("name=\"language\""))
    }

    func testRemoteSpeechEndpointErrorsAreMapped() async throws {
        let transport = MockHTTPTransport(responses: [.json(401, #"{"error":{"message":"bad key"}}"#)])
        let profile = SpeechProfile(engine: .customEndpoint, remoteBaseURL: "https://stt.example.com/v1")
        let transcriber = RemoteSpeechTranscriber(profile: profile, apiKey: "wrong", transport: transport)
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data(repeating: 1, count: 2_048).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        do {
            _ = try await transcriber.transcribe(audioAt: audioURL)
            XCTFail("Expected an error")
        } catch let error as AppError {
            guard case .providerUnauthorized = error else { return XCTFail("Unexpected: \(error)") }
        }
    }

    // MARK: Credentials

    func testAPIKeyReferenceIsStoredInSecretStoreAndNeverOnProfile() throws {
        let store = InMemorySecretStore()
        var profile = makeProfile()
        try ProviderCredentials.applyAPIKey("  sk-abc  ", to: &profile, secretStore: store)
        XCTAssertEqual(profile.keychainRef, "provider-\(profile.id.rawValue)")
        XCTAssertEqual(try ProviderCredentials.apiKey(for: profile, secretStore: store), "sk-abc")
        try ProviderCredentials.applyAPIKey(nil, to: &profile, secretStore: store)
        XCTAssertNil(profile.keychainRef)
        XCTAssertNil(try ProviderCredentials.apiKey(for: profile, secretStore: store))
    }

    // MARK: Helpers

    private func makeProfile() -> ProviderProfile {
        ProviderProfile(
            name: "Test",
            baseURL: "https://example.test/v1",
            apiStyle: .chatCompletions,
            modelId: "test-model",
            keychainRef: nil,
            requiresAuthentication: true,
            timeoutSeconds: 30,
            maxRetries: 0
        )
    }
}

// MARK: - Mock transport

final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    enum Stub {
        case json(Int, String)
        case raw(Int, Data)
        case response(HTTPResponse)
    }

    private var stubs: [Stub]
    private(set) var requests: [URLRequest] = []

    init(responses: [Stub]) {
        self.stubs = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !stubs.isEmpty else {
            throw AppError.providerHTTPError(status: 500, message: "No stub left")
        }
        let stub = stubs.removeFirst()
        switch stub {
        case .json(let status, let body):
            return HTTPResponse(data: Data(body.utf8), statusCode: status, headers: [:])
        case .raw(let status, let data):
            return HTTPResponse(data: data, statusCode: status, headers: [:])
        case .response(let response):
            return response
        }
    }
}
