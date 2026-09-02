import CryptoKit
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
    guard !transcript.segments.isEmpty else { throw LMStudioError.incompleteTranscript }
    guard input.transcriptSegmentCount == transcript.segments.count else {
      throw LMStudioError.inconsistentInput(
        "transcript segment count does not match canonical transcript")
    }
    guard input.rawNotesRevision == rawNotes.revision else {
      throw LMStudioError.inconsistentInput(
        "raw-note revision is not the frozen canonical revision")
    }
    if let rawNotesSHA256 = input.rawNotesSHA256,
      try rawNotesDigest(rawNotes) != rawNotesSHA256
    {
      throw LMStudioError.inconsistentInput("raw-note digest is not the frozen canonical content")
    }
    try Task.checkCancellation()
    let chunks = try promptBuilder.chunks(
      for: transcript, tokenBudget: configuration.chunkTokenBudget)
    var partials: [BriefResponseDecoder.ModelBriefPayload] = []
    for chunk in chunks {
      try Task.checkCancellation()
      let request = try promptBuilder.extractionRequest(
        modelID: configuration.modelID, chunk: chunk, rawNotes: rawNotes)
      let response = try await client.postChatCompletion(
        body: request, configuration: configuration)
      let payload = try responseDecoder.decodePayload(from: response)
      try responseDecoder.validateEvidenceIDs(payload, against: transcript)
      partials.append(promptBuilder.namespaced(payload, namespace: "c\(chunk.index + 1)"))
    }
    // A single extraction is already a complete bounded brief. Sending it
    // through a second model reduction is both wasteful and, when the
    // extraction contains no evidence-backed items, used to produce an
    // impossible schema (`enum: []` together with `minItems: 1`).
    let finalPayload: BriefResponseDecoder.ModelBriefPayload
    if partials.count == 1, let only = partials.first {
      finalPayload = promptBuilder.namespaced(only, namespace: "final")
    } else if partials.allSatisfy({ $0.hasNoEvidenceBackedItems }) {
      finalPayload = consolidateEmptyPartials(partials)
    } else {
      finalPayload = try await reduceHierarchically(
        partials, transcript: transcript, rawNotes: rawNotes)
    }
    try Task.checkCancellation()
    return try responseDecoder.makeMeetingBrief(
      payload: finalPayload,
      transcript: transcript,
      input: input,
      configuration: configuration
    )
  }

  private func reduceHierarchically(
    _ partials: [BriefResponseDecoder.ModelBriefPayload],
    transcript: SessionTranscript,
    rawNotes: RawMeetingNotes
  ) async throws -> BriefResponseDecoder.ModelBriefPayload {
    var layer = partials
    var round = 0
    while true {
      try Task.checkCancellation()
      let batches = try promptBuilder.reductionBatches(
        for: layer, tokenBudget: configuration.chunkTokenBudget)
      var reduced: [BriefResponseDecoder.ModelBriefPayload] = []
      for (batchIndex, batch) in batches.enumerated() {
        try Task.checkCancellation()
        let request = try promptBuilder.reductionRequest(
          modelID: configuration.modelID, partials: batch, rawNotes: rawNotes)
        let response = try await client.postChatCompletion(
          body: request, configuration: configuration)
        let payload = try responseDecoder.decodePayload(from: response)
        try responseDecoder.validateEvidenceIDs(payload, against: transcript)
        reduced.append(
          promptBuilder.namespaced(payload, namespace: "r\(round + 1)b\(batchIndex + 1)")
        )
      }
      if reduced.count == 1 {
        return promptBuilder.namespaced(reduced[0], namespace: "final")
      }
      // A layer of one-item batches cannot reduce the number of partials
      // without exceeding the configured bound, so fail rather than loop
      // indefinitely or send an unbounded request.
      guard reduced.count < layer.count else {
        throw LMStudioError.tokenBudgetExceeded(segmentID: "generated-partial")
      }
      layer = reduced
      round += 1
    }
  }

  private func rawNotesDigest(_ rawNotes: RawMeetingNotes) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = SHA256.hash(data: try encoder.encode(rawNotes))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Preserve model-produced coverage text without asking the model to reduce
  /// a collection that contains no citable items. The final brief still shows
  /// the raw notes separately and carries Quill's mandatory review warning.
  private func consolidateEmptyPartials(
    _ partials: [BriefResponseDecoder.ModelBriefPayload]
  ) -> BriefResponseDecoder.ModelBriefPayload {
    let overviews = partials.map(\.overview)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let uniqueOverviews = overviews.reduce(into: [String]()) { result, overview in
      if !result.contains(overview) { result.append(overview) }
    }
    let language = partials.lazy.map(\.language)
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "undetermined"
    return .init(
      language: language,
      overview: uniqueOverviews.joined(separator: "\n\n"),
      topics: [],
      decisions: [],
      actionItems: [],
      openQuestions: [],
      warnings: []
    )
  }
}

private extension BriefResponseDecoder.ModelBriefPayload {
  var hasNoEvidenceBackedItems: Bool {
    topics.isEmpty && decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty
  }
}
