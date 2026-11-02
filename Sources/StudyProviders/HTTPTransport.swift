import Foundation
import StudyDomain

public struct HTTPResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    public var headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// URLSession transport with two protections that matter here:
/// redirects to another host drop the Authorization header, and redirects to
/// plain HTTP on a non-loopback host are refused.
public struct URLSessionHTTPTransport: HTTPTransport {
    public var maximumResponseBytes: Int

    public init(maximumResponseBytes: Int = 8 * 1024 * 1024) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval > 0 ? request.timeoutInterval : 60
        configuration.timeoutIntervalForResource = max(60, request.timeoutInterval * 2)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never

        let delegate = RedirectGuard()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.providerMalformedResponse("The response was not an HTTP response.")
            }
            guard data.count <= maximumResponseBytes else {
                throw AppError.providerMalformedResponse("The response was larger than the app accepts.")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            return HTTPResponse(data: data, statusCode: http.statusCode, headers: headers)
        } catch let error as URLError {
            throw ProviderErrorMapping.map(error)
        }
    }
}

final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalHost = task.originalRequest?.url?.host?.lowercased(),
              let newHost = request.url?.host?.lowercased(),
              let scheme = request.url?.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && ProviderEndpoint.isLoopback(host: newHost))
        else {
            completionHandler(nil)
            return
        }
        guard newHost != originalHost else {
            completionHandler(request)
            return
        }
        var sanitized = request
        for header in ["Authorization", "api-key", "x-api-key", "Proxy-Authorization"] {
            sanitized.setValue(nil, forHTTPHeaderField: header)
        }
        completionHandler(sanitized)
    }
}

public enum ProviderErrorMapping {
    public static func map(_ error: URLError) -> AppError {
        switch error.code {
        case .timedOut:
            return .providerTimeout
        case .cancelled:
            return .providerCancelled
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return .providerOffline
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            return .providerHTTPError(status: 0, message: "The secure connection to the provider failed.")
        default:
            return .providerHTTPError(status: 0, message: error.localizedDescription)
        }
    }

    public static func httpError(status: Int, headers: [String: String], body: Data) -> AppError {
        let message = providerMessage(from: body)
        switch status {
        case 401:
            return .providerUnauthorized(message)
        case 403:
            return .providerForbidden(message)
        case 404:
            return .providerNotFound(message)
        case 429:
            return .providerRateLimited(retryAfter: retryAfter(headers: headers))
        case 400, 422:
            return .providerHTTPError(status: status, message: message)
        case 500...599:
            return .providerServerError(status: status)
        default:
            return .providerHTTPError(status: status, message: message)
        }
    }

    public static func retryAfter(headers: [String: String]) -> TimeInterval? {
        guard let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(raw) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    /// Extracts a short provider message; never returns the raw body verbatim.
    static func providerMessage(from body: Data) -> String {
        guard !body.isEmpty else { return "The provider returned an empty response." }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] {
                if let dictionary = error as? [String: Any], let message = dictionary["message"] as? String {
                    return sanitize(message)
                }
                if let message = error as? String { return sanitize(message) }
            }
            if let message = object["message"] as? String { return sanitize(message) }
            if let detail = object["detail"] as? String { return sanitize(detail) }
        }
        if let text = String(data: body, encoding: .utf8) {
            return sanitize(text)
        }
        return "The provider returned an unreadable error body."
    }

    static func sanitize(_ message: String) -> String {
        let collapsed = TextUtilities.normalizeWhitespace(message)
        if collapsed.isEmpty { return "The provider returned an error." }
        return String(collapsed.prefix(300))
    }
}

// MARK: - JSON extraction

public enum JSONExtraction {
    /// Accepts a bare JSON object or one wrapped in a Markdown fence or prose,
    /// as some OpenAI-compatible servers do even when asked for JSON.
    public static func objectData(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
            return data
        }
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start < end {
            let candidate = String(trimmed[start...end])
            if let data = candidate.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
                return data
            }
        }
        return nil
    }
}
