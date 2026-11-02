import Foundation
import StudyDomain

/// Validates provider URLs and resolves the operation endpoint.
///
/// Remote hosts must use HTTPS. Plain HTTP is allowed only for loopback,
/// where no traffic leaves the machine.
public enum ProviderEndpoint {

    public static func validateBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.providerInvalidURL("Enter the base URL of the provider.")
        }
        guard var components = URLComponents(string: trimmed) else {
            throw AppError.providerInvalidURL("The URL could not be parsed.")
        }
        guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw AppError.providerInvalidURL("Use an http(s) URL.")
        }
        guard let host = components.host, !host.isEmpty else {
            throw AppError.providerInvalidURL("The URL has no host.")
        }
        if components.user != nil || components.password != nil {
            throw AppError.providerInvalidURL("Do not put credentials in the URL; the API key is stored in the Keychain.")
        }
        if scheme == "http" && !isLoopback(host: host) {
            throw AppError.providerInsecureURL("Use HTTPS for \(host); plain HTTP is only allowed for localhost.")
        }
        if components.fragment != nil {
            components.fragment = nil
        }
        guard let url = components.url else {
            throw AppError.providerInvalidURL("The URL could not be parsed.")
        }
        return url
    }

    /// The client identifies itself honestly; it never impersonates a coding agent.
    public static let clientUserAgent = "StudyApp/1.0 (macOS; document-grounded study app)"

    public static func isOpenCodeHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return host == "opencode.ai" || host.hasSuffix(".opencode.ai")
    }

    public static func isLoopback(host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized.hasPrefix("127.")
    }

    /// Combines the base URL with the endpoint for the selected API style,
    /// accepting either a base URL (`…/v1`) or a full endpoint URL.
    public static func endpointURL(baseURL: String, style: ProviderAPIStyle) throws -> URL {
        let base = try validateBaseURL(baseURL)
        let desiredSuffix = style == .chatCompletions ? "chat/completions" : "responses"
        let undesiredSuffix = style == .chatCompletions ? "responses" : "chat/completions"

        var path = base.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/" + undesiredSuffix) {
            path.removeLast(undesiredSuffix.count + 1)
        }
        if !path.hasSuffix("/" + desiredSuffix) {
            path += "/" + desiredSuffix
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AppError.providerInvalidURL("The URL could not be parsed.")
        }
        components.path = path.isEmpty ? "/" + desiredSuffix : path
        components.query = nil
        guard let url = components.url else {
            throw AppError.providerInvalidURL("The endpoint URL could not be built.")
        }
        return url
    }

    /// Resolves an audio transcription endpoint from a custom STT base URL.
    public static func transcriptionEndpointURL(baseURL: String) throws -> URL {
        let base = try validateBaseURL(baseURL)
        var path = base.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/audio/transcriptions") {
            path += "/audio/transcriptions"
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AppError.providerInvalidURL("The URL could not be parsed.")
        }
        components.path = path
        components.query = nil
        guard let url = components.url else {
            throw AppError.providerInvalidURL("The endpoint URL could not be built.")
        }
        return url
    }
}
