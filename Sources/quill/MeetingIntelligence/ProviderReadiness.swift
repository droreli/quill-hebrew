import Foundation

/// The deliberately narrow configuration surface for the optional LM Studio
/// adapter. It is value-only: callers decide whether and where to persist it.
struct LMStudioProviderConfiguration: Sendable, Equatable {
    static let recommendedPersonalModelID = "google/gemma-4-26b-a4b-qat"
    static let defaultEndpoint = "http://127.0.0.1:1234"

    /// Opt-in is intentionally false. A disabled configuration never probes a
    /// provider and is never consulted by recording or transcription.
    var isEnabled: Bool
    var endpoint: String
    var selectedModelID: String

    init(
        isEnabled: Bool = false,
        endpoint: String = LMStudioProviderConfiguration.defaultEndpoint,
        selectedModelID: String = LMStudioProviderConfiguration.recommendedPersonalModelID
    ) {
        self.isEnabled = isEnabled
        self.endpoint = endpoint
        self.selectedModelID = selectedModelID
    }
}

enum LoopbackProviderEndpointError: Error, Equatable, LocalizedError {
    case invalidEndpoint

    var errorDescription: String? {
        "Use an HTTP URL with the literal host 127.0.0.1 or ::1."
    }
}

/// A canonical loopback base URL. Host rules intentionally mirror
/// `GenerationProvenance`: names such as `localhost`, DNS aliases, credentials,
/// and non-HTTP schemes are not accepted.
struct LoopbackProviderEndpoint: Sendable, Equatable {
    let url: URL

    init(validating value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http",
              let unbracketedHost = components.host?.lowercased(),
              ["127.0.0.1", "::1"].contains(unbracketedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = components.url
        else {
            throw LoopbackProviderEndpointError.invalidEndpoint
        }
        self.url = url
    }

    var modelsURL: URL {
        // The validated base has no path beyond an optional root slash, so a
        // fixed endpoint cannot be redirected into another provider route.
        url.appendingPathComponent("v1", isDirectory: true).appendingPathComponent("models")
    }
}

struct ProviderHTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let body: Data

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// Kept injectable so readiness has no test-only network path.
protocol LoopbackProviderHTTPClient: Sendable {
    func get(_ url: URL) async throws -> ProviderHTTPResponse
}

/// Production transport for the explicit readiness check. It is intentionally
/// separate from the provider configuration: constructing it performs no I/O.
/// Requests use an ephemeral, proxy-free session and reject every redirect.
final class LoopbackModelsHTTPClient: @unchecked Sendable, LoopbackProviderHTTPClient {
    private let session: URLSession
    private let timeout: TimeInterval
    private let redirectRefuser: LoopbackModelsRedirectRefuser

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let redirectRefuser = LoopbackModelsRedirectRefuser()
        self.redirectRefuser = redirectRefuser
        self.session = URLSession(configuration: configuration, delegate: redirectRefuser, delegateQueue: nil)
    }

    func get(_ url: URL) async throws -> ProviderHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (body, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return ProviderHTTPResponse(statusCode: response.statusCode, body: body)
    }
}

private final class LoopbackModelsRedirectRefuser: NSObject, URLSessionTaskDelegate {
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

enum ProviderModelIdentityProvenance: String, Sendable, Equatable, Codable {
    /// IDs come from `/v1/models`; the provider does not expose a verified
    /// model file digest, so checksum provenance remains unavailable.
    case reported
}

struct ProviderModelIdentity: Sendable, Equatable, Codable, Identifiable {
    let id: String
    let provenance: ProviderModelIdentityProvenance
    let checksumSHA256: String?

    init(id: String, provenance: ProviderModelIdentityProvenance = .reported, checksumSHA256: String? = nil) {
        self.id = id
        self.provenance = provenance
        self.checksumSHA256 = checksumSHA256
    }
}

struct ProviderModelInventory: Sendable, Equatable {
    let models: [ProviderModelIdentity]
    let selectedModelID: String

    var selectedModelIsAvailable: Bool {
        models.contains { $0.id == selectedModelID }
    }
}

enum ProviderReadinessFailure: Sendable, Equatable {
    case invalidConfiguration(String)
    case providerUnavailable(String)
    case timedOut
    case invalidResponse(String)
}

enum ProviderReadiness: Sendable, Equatable {
    case disabled
    case ready(ProviderModelInventory)
    case unavailable(ProviderReadinessFailure)
}

/// A small, post-transcript-safe readiness service. It deliberately owns no
/// recording, transcription, model install, or preference-writing behavior.
struct LMStudioProviderReadinessService: Sendable {
    let client: any LoopbackProviderHTTPClient
    let timeoutNanoseconds: UInt64

    init(client: any LoopbackProviderHTTPClient, timeoutNanoseconds: UInt64 = 5_000_000_000) {
        self.client = client
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func check(_ configuration: LMStudioProviderConfiguration) async throws -> ProviderReadiness {
        guard configuration.isEnabled else { return .disabled }
        guard !configuration.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(.invalidConfiguration("Choose a model before checking the provider."))
        }

        let endpoint: LoopbackProviderEndpoint
        do {
            endpoint = try LoopbackProviderEndpoint(validating: configuration.endpoint)
        } catch {
            return .unavailable(.invalidConfiguration("Use a literal HTTP loopback endpoint."))
        }

        do {
            let response = try await requestWithTimeout(endpoint.modelsURL)
            guard (200...299).contains(response.statusCode) else {
                return .unavailable(.providerUnavailable("The local server returned HTTP \(response.statusCode)."))
            }
            return .ready(try decodeInventory(response.body, selectedModelID: configuration.selectedModelID))
        } catch is CancellationError {
            throw CancellationError()
        } catch ProviderReadinessTimeoutError.timedOut {
            return .unavailable(.timedOut)
        } catch let error as ProviderReadinessDecodingError {
            return .unavailable(.invalidResponse(error.message))
        } catch {
            return .unavailable(.providerUnavailable("The local LM Studio server is unavailable."))
        }
    }

    private func requestWithTimeout(_ url: URL) async throws -> ProviderHTTPResponse {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: ProviderHTTPResponse.self) { group in
            group.addTask { try await client.get(url) }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                try Task.checkCancellation()
                throw ProviderReadinessTimeoutError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    private func decodeInventory(_ data: Data, selectedModelID: String) throws -> ProviderModelInventory {
        let payload: ModelsPayload
        do {
            payload = try JSONDecoder().decode(ModelsPayload.self, from: data)
        } catch {
            throw ProviderReadinessDecodingError(message: "LM Studio returned an invalid /v1/models response.")
        }
        let uniqueIDs = Set(payload.data.map(\.id))
        guard uniqueIDs.count == payload.data.count, payload.data.allSatisfy({ !$0.id.isEmpty }) else {
            throw ProviderReadinessDecodingError(message: "LM Studio returned invalid model identifiers.")
        }
        return ProviderModelInventory(
            models: payload.data.map { ProviderModelIdentity(id: $0.id) },
            selectedModelID: selectedModelID
        )
    }
}

private enum ProviderReadinessTimeoutError: Error {
    case timedOut
}

private struct ProviderReadinessDecodingError: Error {
    let message: String
}

private struct ModelsPayload: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}
