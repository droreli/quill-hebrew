import Foundation

/// Errors exposed by the opt-in local LM Studio provider. None of these errors
/// triggers a remote fallback; callers can safely leave capture and
/// transcription running when the provider is unavailable.
enum LMStudioError: Error, Equatable, LocalizedError {
    case disabled
    case invalidEndpoint(String)
    case providerUnavailable
    case requestTimedOut
    case cancelled
    case invalidResponse(statusCode: Int)
    case malformedResponse
    case responseTooLarge(limit: Int)
    case tokenBudgetExceeded(segmentID: String)
    case inconsistentInput(String)
    case incompleteTranscript

    var errorDescription: String? {
        switch self {
        case .disabled: "The local LM Studio provider is disabled."
        case let .invalidEndpoint(reason): "Invalid LM Studio loopback endpoint: \(reason)"
        case .providerUnavailable: "The configured local LM Studio server or model is unavailable."
        case .requestTimedOut: "The local LM Studio request timed out."
        case .cancelled: "The local LM Studio request was cancelled."
        case let .invalidResponse(statusCode): "LM Studio returned HTTP \(statusCode)."
        case .malformedResponse: "LM Studio returned malformed structured output."
        case let .responseTooLarge(limit): "LM Studio response exceeded the \(limit)-byte limit."
        case let .tokenBudgetExceeded(segmentID): "Transcript segment \(segmentID) exceeds the local model token budget."
        case let .inconsistentInput(reason): "Meeting brief inputs are inconsistent: \(reason)"
        case .incompleteTranscript: "The transcript has no canonical segments; Quill must report incomplete coverage without model inference."
        }
    }
}

/// Validated local provider settings. The initial model is a profile default,
/// not an exclusive or public model default; callers may configure another
/// locally available model.
struct LMStudioConfiguration: Sendable, Equatable {
    static let initialModelID = "google/gemma-4-26b-a4b-qat"

    let endpoint: URL
    let modelID: String
    let isEnabled: Bool
    let requestTimeout: TimeInterval
    let maximumResponseBytes: Int
    let chunkTokenBudget: Int

    init(
        endpoint: String = "http://127.0.0.1:1234",
        modelID: String = LMStudioConfiguration.initialModelID,
        isEnabled: Bool = false,
        requestTimeout: TimeInterval = 300,
        maximumResponseBytes: Int = 1_000_000,
        chunkTokenBudget: Int = 6_000
    ) throws {
        self.endpoint = try Self.validateLoopbackEndpoint(endpoint)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LMStudioError.invalidEndpoint("model ID is empty")
        }
        guard requestTimeout > 0, maximumResponseBytes > 0, chunkTokenBudget > 0 else {
            throw LMStudioError.invalidEndpoint("timeout, response cap, and token budget must be positive")
        }
        self.modelID = modelID
        self.isEnabled = isEnabled
        self.requestTimeout = requestTimeout
        self.maximumResponseBytes = maximumResponseBytes
        self.chunkTokenBudget = chunkTokenBudget
    }

    /// Accept only literal HTTP loopback roots. Paths, queries, fragments,
    /// credentials, and host aliases such as `localhost` are intentionally
    /// refused before a request can be created.
    static func validateLoopbackEndpoint(_ value: String) throws -> URL {
        do {
            return try LoopbackProviderEndpoint(validating: value).url
        } catch {
            throw LMStudioError.invalidEndpoint("must be literal http://127.0.0.1 or http://[::1] with no path or credentials")
        }
    }
}

/// Small, injectable HTTP boundary for the only permitted network operation.
/// Its session uses no proxy configuration and its redirect delegate cancels
/// every redirect, including a loopback-to-loopback redirect.
final class LoopbackHTTPClient: NSObject, @unchecked Sendable {
    private let session: URLSession
    private let maximumResponseBytes: Int

    init(configuration: LMStudioConfiguration, session: URLSession? = nil) {
        self.maximumResponseBytes = configuration.maximumResponseBytes
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.connectionProxyDictionary = [:]
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
            sessionConfiguration.timeoutIntervalForResource = configuration.requestTimeout
            self.session = URLSession(configuration: sessionConfiguration, delegate: LoopbackRedirectRefuser(), delegateQueue: nil)
        }
        super.init()
    }

    func postChatCompletion(body: Data, configuration: LMStudioConfiguration) async throws -> Data {
        guard configuration.isEnabled else { throw LMStudioError.disabled }
        var request = URLRequest(url: chatCompletionURL(for: configuration.endpoint))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw LMStudioError.malformedResponse
            }
            guard (200...299).contains(http.statusCode) else {
                if [400, 404, 422, 429, 500, 502, 503, 504].contains(http.statusCode) {
                    throw LMStudioError.providerUnavailable
                }
                throw LMStudioError.invalidResponse(statusCode: http.statusCode)
            }
            if let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
               let declaredLength = Int(contentLength), declaredLength > maximumResponseBytes {
                throw LMStudioError.responseTooLarge(limit: maximumResponseBytes)
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumResponseBytes else {
                    throw LMStudioError.responseTooLarge(limit: maximumResponseBytes)
                }
                data.append(byte)
            }
            return data
        } catch is CancellationError {
            throw LMStudioError.cancelled
        } catch let error as LMStudioError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw LMStudioError.requestTimedOut
            case .cancelled:
                throw LMStudioError.cancelled
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable:
                throw LMStudioError.providerUnavailable
            default:
                throw LMStudioError.providerUnavailable
            }
        }
    }

    private func chatCompletionURL(for endpoint: URL) -> URL {
        endpoint.appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
    }
}

private final class LoopbackRedirectRefuser: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
