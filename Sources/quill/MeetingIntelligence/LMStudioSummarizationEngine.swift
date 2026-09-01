import Foundation

/// Opt-in, local-only OpenAI-compatible LM Studio implementation. It does not
/// manage LM Studio, probes readiness, install models, or provide cloud fallback.
struct LMStudioSummarizationEngine: SummarizationEngine, Sendable {
    let configuration: LMStudioConfiguration
    private let client: LoopbackHTTPClient
    private let promptBuilder: PromptBuilder
    private let responseDecoder: BriefResponseDecoder

    init(
        configuration: LMStudioConfiguration,
        session: URLSession? = nil,
        promptBuilder: PromptBuilder = .init(),
        responseDecoder: BriefResponseDecoder = .init()
    ) {
        self.configuration = configuration
        self.client = LoopbackHTTPClient(configuration: configuration, session: session)
        self.promptBuilder = promptBuilder
        self.responseDecoder = responseDecoder
    }

    func summarize(
        transcript: SessionTranscript,
        rawNotes: RawMeetingNotes,
        input: SummaryInput
    ) async throws -> MeetingBrief {
        guard configuration.isEnabled else { throw LMStudioError.disabled }
        try transcript.validate()
        try rawNotes.validate()
        guard input.transcriptSegmentCount == transcript.segments.count else {
            throw LMStudioError.inconsistentInput("transcript segment count does not match canonical transcript")
        }
        guard input.rawNotesRevision == rawNotes.revision else {
            throw LMStudioError.inconsistentInput("raw-note revision is not the frozen canonical revision")
        }
        try Task.checkCancellation()
        let chunks = try promptBuilder.chunks(for: transcript, tokenBudget: configuration.chunkTokenBudget)
        var partials: [BriefResponseDecoder.ModelBriefPayload] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let request = try promptBuilder.extractionRequest(modelID: configuration.modelID, chunk: chunk, rawNotes: rawNotes)
            let response = try await client.postChatCompletion(body: request, configuration: configuration)
            let payload = try responseDecoder.decodePayload(from: response)
            try responseDecoder.validateEvidenceIDs(payload, against: transcript)
            partials.append(payload)
        }
        try Task.checkCancellation()
        let reductionRequest = try promptBuilder.reductionRequest(modelID: configuration.modelID, partials: partials, rawNotes: rawNotes)
        let reductionResponse = try await client.postChatCompletion(body: reductionRequest, configuration: configuration)
        let finalPayload = try responseDecoder.decodePayload(from: reductionResponse)
        try Task.checkCancellation()
        return try responseDecoder.makeMeetingBrief(
            payload: finalPayload,
            transcript: transcript,
            input: input,
            configuration: configuration
        )
    }
}
