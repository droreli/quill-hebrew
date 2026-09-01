import Foundation
import Testing
@testable import quill

@Test func providerIsDisabledByDefaultAndDoesNotProbe() async throws {
    let client = FakeProviderClient(response: .init(statusCode: 200, body: modelsJSON(["google/gemma-4-26b-a4b-qat"])))
    let service = LMStudioProviderReadinessService(client: client)

    let readiness = try await service.check(.init())

    #expect(readiness == .disabled)
    #expect(await client.requestCount == 0)
}

@Test func literalLoopbackValidatorRejectsNamesCredentialsAndRoutes() {
    for invalid in [
        "http://localhost:1234",
        "https://127.0.0.1:1234",
        "http://user@127.0.0.1:1234",
        "http://127.0.0.1:1234/v1/models",
        "http://127.0.0.1:1234?next=https://example.com",
        "http://127.0.0.2:1234",
    ] {
        #expect(throws: LoopbackProviderEndpointError.self) {
            try LoopbackProviderEndpoint(validating: invalid)
        }
    }
    #expect(throws: Never.self) { try LoopbackProviderEndpoint(validating: "http://127.0.0.1:1234") }
    #expect(throws: Never.self) { try LoopbackProviderEndpoint(validating: "http://[::1]:1234") }
}

@Test func enabledProviderUsesOnlyModelsEndpointAndReportsProvenance() async throws {
    let client = FakeProviderClient(response: .init(statusCode: 200, body: modelsJSON([
        "google/gemma-4-26b-a4b-qat", "qwen/qwen3.8-27b",
    ])))
    let service = LMStudioProviderReadinessService(client: client)
    let configuration = LMStudioProviderConfiguration(isEnabled: true)

    let readiness = try await service.check(configuration)

    guard case let .ready(inventory) = readiness else {
        Issue.record("Expected provider readiness")
        return
    }
    #expect(await client.requestedURLs == [URL(string: "http://127.0.0.1:1234/v1/models")!])
    #expect(inventory.selectedModelIsAvailable)
    #expect(inventory.models.allSatisfy { $0.provenance == .reported && $0.checksumSHA256 == nil })
}

@Test func missingSelectedModelIsGuidanceNotProviderFailure() async throws {
    let client = FakeProviderClient(response: .init(statusCode: 200, body: modelsJSON(["another/model"])))
    let service = LMStudioProviderReadinessService(client: client)
    let configuration = LMStudioProviderConfiguration(isEnabled: true, selectedModelID: "not/loaded")

    let readiness = try await service.check(configuration)

    guard case let .ready(inventory) = readiness else {
        Issue.record("The running provider should still be ready")
        return
    }
    #expect(!inventory.selectedModelIsAvailable)
}

@Test func enabledProbeTimesOutAndCancellationPropagates() async throws {
    let client = FakeProviderClient(delayNanoseconds: 100_000_000)
    let service = LMStudioProviderReadinessService(client: client, timeoutNanoseconds: 1_000_000)
    let timedOut = try await service.check(.init(isEnabled: true))
    #expect(timedOut == .unavailable(.timedOut))

    let cancelled = Task { try await LMStudioProviderReadinessService(client: FakeProviderClient(delayNanoseconds: 100_000_000)).check(.init(isEnabled: true)) }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

private actor FakeProviderClient: LoopbackProviderHTTPClient {
    let response: ProviderHTTPResponse
    let delayNanoseconds: UInt64
    private(set) var requestedURLs: [URL] = []
    private(set) var requestCount = 0

    init(response: ProviderHTTPResponse = .init(statusCode: 200, body: Data("{\"data\":[]}".utf8)), delayNanoseconds: UInt64 = 0) {
        self.response = response
        self.delayNanoseconds = delayNanoseconds
    }

    func get(_ url: URL) async throws -> ProviderHTTPResponse {
        requestCount += 1
        requestedURLs.append(url)
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return response
    }
}

private func modelsJSON(_ ids: [String]) -> Data {
    let objects = ids.map { ["id": $0] }
    return try! JSONSerialization.data(withJSONObject: ["data": objects])
}
