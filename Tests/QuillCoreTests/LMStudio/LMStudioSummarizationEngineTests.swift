import Foundation
import Testing
@testable import quill

@Test func LMStudioConfigurationOnlyAcceptsLiteralLoopbackRoots() throws {
    for endpoint in [
        "https://127.0.0.1:1234",
        "http://localhost:1234",
        "http://127.0.0.1:1234/v1",
        "http://127.0.0.1:1234?proxy=1",
        "http://user@127.0.0.1:1234",
        "http://127.0.0.1.evil.example:1234",
    ] {
        #expect(throws: LMStudioError.self) {
            try LMStudioConfiguration(endpoint: endpoint)
        }
    }
    #expect(try LMStudioConfiguration(endpoint: "http://127.0.0.1:1234", modelID: "local/custom", isEnabled: true).modelID == "local/custom")
    #expect(try LMStudioConfiguration(endpoint: "http://[::1]:1234").endpoint.host == "::1")
}

@Test func generationProvenanceAlsoRejectsNonRootLoopbackEndpoints() {
    for endpoint in [
        "http://127.0.0.1:1234/v1",
        "http://127.0.0.1:1234?next=1",
        "http://127.0.0.1:1234#fragment",
        "http://localhost:1234",
    ] {
        #expect(throws: MeetingIntelligenceContractError.self) {
            try GenerationProvenance(
                engine: "fixture", endpoint: endpoint, runtimeVersion: "test",
                modelID: "fixture", modelRevision: nil, quantization: "none",
                localOnly: true, provenance: "fixture"
            )
        }
    }
}

@Test func engineUsesOnlyChatCompletionsAndEnrichesCanonicalEvidence() async throws {
    let port = 15101
    FakeLMStudioURLProtocol.configure(port: port, responses: [
        .success(openAIResponse(payload: payload(evidenceID: "s000001"))),
        .success(openAIResponse(payload: payload(evidenceID: "s000002"))),
    ])
    let engine = LMStudioSummarizationEngine(
        configuration: try configuration(port: port),
        session: fakeSession()
    )

    let brief = try await engine.summarize(transcript: transcript(), rawNotes: notes(), input: input())
    #expect(brief.generator.modelID == "local/test-model")
    #expect(brief.generator.localOnly)
    #expect(brief.decisions[0].evidence == [try EvidenceReference(segmentID: "s000002", transcriptJSONPointer: "/segments/1", startMS: 100, endMS: 200, speaker: "them")])

    let requests = FakeLMStudioURLProtocol.requests(port: port)
    #expect(requests.count == 2)
    for request in requests {
        #expect(request.url?.host == "127.0.0.1")
        #expect(request.url?.path == "/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(requestBody(request))
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(object?["model"] as? String == "local/test-model")
        #expect(object?["response_format"] != nil)
    }
}

@Test func chunkingPreservesSegmentBoundariesAndRefusesOversizedSegment() throws {
    let builder = PromptBuilder()
    let source = try SessionTranscript(
        engine: "fixture", model: "fixture", createdAt: "2026-09-01T00:00:00Z", speakerLabels: true, timestamps: true,
        segments: [
            .init(id: "s000001", speaker: "me", startMS: 0, endMS: 100, text: "first bounded segment"),
            .init(id: "s000002", speaker: "them", startMS: 100, endMS: 200, text: "second bounded segment"),
        ]
    )
    let chunks = try builder.chunks(for: source, tokenBudget: 24)
    #expect(chunks.map { $0.segments.map(\.id) } == [["s000001"], ["s000002"]])
    #expect(throws: LMStudioError.self) {
        try builder.chunks(for: source, tokenBudget: 1)
    }
}

@Test func malformedUnknownAndUnavailableLocalResponsesFailSafely() async throws {
    let malformedPort = 15102
    FakeLMStudioURLProtocol.configure(port: malformedPort, responses: [.success(Data("{bad".utf8))])
    let malformedEngine = LMStudioSummarizationEngine(configuration: try configuration(port: malformedPort), session: fakeSession())
    await #expect(throws: LMStudioError.self) {
        try await malformedEngine.summarize(transcript: transcript(), rawNotes: notes(), input: input())
    }

    let unknownPort = 15103
    FakeLMStudioURLProtocol.configure(port: unknownPort, responses: [.success(openAIResponse(payload: payload(evidenceID: "s999999")))])
    let unknownEngine = LMStudioSummarizationEngine(configuration: try configuration(port: unknownPort), session: fakeSession())
    await #expect(throws: MeetingIntelligenceContractError.self) {
        try await unknownEngine.summarize(transcript: transcript(), rawNotes: notes(), input: input())
    }

    let unavailablePort = 15104
    FakeLMStudioURLProtocol.configure(port: unavailablePort, responses: [.http(status: 503, data: Data())])
    let unavailableEngine = LMStudioSummarizationEngine(configuration: try configuration(port: unavailablePort), session: fakeSession())
    await #expect(throws: LMStudioError.self) {
        try await unavailableEngine.summarize(transcript: transcript(), rawNotes: notes(), input: input())
    }
}

@Test func disabledProviderAndResponseCapAvoidInference() async throws {
    let disabled = LMStudioSummarizationEngine(configuration: try LMStudioConfiguration(isEnabled: false), session: fakeSession())
    await #expect(throws: LMStudioError.self) {
        try await disabled.summarize(transcript: transcript(), rawNotes: notes(), input: input())
    }

    let cappedPort = 15105
    FakeLMStudioURLProtocol.configure(port: cappedPort, responses: [.success(Data(repeating: 65, count: 256))])
    let cappedConfiguration = try LMStudioConfiguration(endpoint: "http://127.0.0.1:\(cappedPort)", modelID: "local/test-model", isEnabled: true, maximumResponseBytes: 32)
    let capped = LMStudioSummarizationEngine(configuration: cappedConfiguration, session: fakeSession())
    await #expect(throws: LMStudioError.self) {
        try await capped.summarize(transcript: transcript(), rawNotes: notes(), input: input())
    }
}

@Test func emptyTranscriptIsRejectedBeforeAnyModelRequest() async throws {
    let port = 15106
    FakeLMStudioURLProtocol.configure(port: port, responses: [])
    let engine = LMStudioSummarizationEngine(configuration: try configuration(port: port), session: fakeSession())
    let empty = try SessionTranscript(
        engine: "fixture", model: "fixture", createdAt: "2026-09-01T00:00:00Z",
        speakerLabels: true, timestamps: true, segments: []
    )
    await #expect(throws: LMStudioError.self) {
        try await engine.summarize(transcript: empty, rawNotes: notes(), input: .init(transcriptSHA256: "fixture", transcriptSegmentCount: 0, rawNotesRevision: 4))
    }
    #expect(FakeLMStudioURLProtocol.requests(port: port).isEmpty)
}

@Test func knownEvidenceIDDoesNotUpgradeInventedModelClaimToVerified() throws {
    let decoder = BriefResponseDecoder()
    let modelPayload = payload(evidenceID: "s000001", decisionText: "The board approved a budget of $10M.")
    let brief = try decoder.makeMeetingBrief(
        payload: modelPayload, transcript: transcript(), input: input(),
        configuration: try configuration(port: 15107), createdAt: "2026-09-01T00:00:00Z", id: "trust-test"
    )
    #expect(brief.decisions[0].support == .aiGeneratedRequiresReview)
    #expect(brief.overviewSupport == .aiGeneratedRequiresReview)
    #expect(brief.warnings.contains(MeetingBrief.requiredReviewWarning))
    #expect(BriefMarkdownRenderer.render(brief).contains("AI-generated draft — requires review"))
}

@Test func decoderRejectsUncitedStructuredModelItems() throws {
    let decoder = BriefResponseDecoder()
    let invalid = BriefResponseDecoder.ModelBriefPayload(
        language: "english", overview: "Unverified overview.",
        topics: [.init(id: "topic-1", text: "No source", evidenceSegmentIDs: [])],
        decisions: [], actionItems: [], openQuestions: [], warnings: []
    )
    #expect(throws: LMStudioError.self) {
        try decoder.makeMeetingBrief(payload: invalid, transcript: transcript(), input: input(), configuration: try configuration(port: 15108))
    }
}

private func configuration(port: Int) throws -> LMStudioConfiguration {
    try LMStudioConfiguration(endpoint: "http://127.0.0.1:\(port)", modelID: "local/test-model", isEnabled: true, chunkTokenBudget: 128)
}

private func fakeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FakeLMStudioURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func transcript() throws -> SessionTranscript {
    try SessionTranscript(
        engine: "fixture", model: "fixture", createdAt: "2026-09-01T00:00:00Z", speakerLabels: true, timestamps: true,
        segments: [
            .init(id: "s000001", speaker: "me", startMS: 0, endMS: 100, text: "We should run a pilot."),
            .init(id: "s000002", speaker: "them", startMS: 100, endMS: 200, text: "Dana will send the proposal Friday."),
        ]
    )
}

private func notes() throws -> RawMeetingNotes {
    try RawMeetingNotes(sessionID: "fixture", revision: 4, template: "general", updatedAt: "2026-09-01T00:00:00Z", notes: [])
}

private func input() -> SummaryInput {
    .init(transcriptSHA256: "fixture", transcriptSegmentCount: 2, rawNotesRevision: 4)
}

private func payload(evidenceID: String, decisionText: String = "Run a pilot") -> BriefResponseDecoder.ModelBriefPayload {
    .init(
        language: "english",
        overview: "Pilot discussion.",
        topics: [],
        decisions: [.init(id: "decision-1", text: decisionText, evidenceSegmentIDs: [evidenceID])],
        actionItems: [],
        openQuestions: [],
        warnings: []
    )
}

private func openAIResponse(payload: BriefResponseDecoder.ModelBriefPayload) -> Data {
    let content = String(decoding: try! JSONEncoder().encode(payload), as: UTF8.self)
    return try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
}

private func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { return nil }
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data
}

private final class FakeLMStudioURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case success(Data)
        case http(status: Int, data: Data)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var repliesByPort: [Int: [Reply]] = [:]
    nonisolated(unsafe) private static var requestsByPort: [Int: [URLRequest]] = [:]

    static func configure(port: Int, responses: [Reply]) {
        lock.lock()
        repliesByPort[port] = responses
        requestsByPort[port] = []
        lock.unlock()
    }

    static func requests(port: Int) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestsByPort[port, default: []]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let port = request.url?.port ?? 80
        Self.lock.lock()
        Self.requestsByPort[port, default: []].append(request)
        let reply = Self.repliesByPort[port, default: []].isEmpty ? nil : Self.repliesByPort[port]!.removeFirst()
        Self.lock.unlock()
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch reply {
        case let .success(data):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .http(status, data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
