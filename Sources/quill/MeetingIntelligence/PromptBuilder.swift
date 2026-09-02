import Foundation

/// Builds bounded, segment-aligned structured-output prompts. It deliberately
/// includes only the canonical transcript and frozen raw notes, never audio.
struct PromptBuilder: Sendable {
  struct Chunk: Sendable, Equatable {
    let index: Int
    let segments: [SessionTranscript.Segment]
    let estimatedTokens: Int
  }

  private struct ChatRequest: Encodable {
    struct Message: Encodable {
      let role: String
      let content: String
    }

    struct ResponseFormat: Encodable {
      struct JSONSchema: Encodable {
        let name: String
        let strict: Bool
        let schema: JSONValue

        enum CodingKeys: String, CodingKey {
          case name
          case strict
          case schema
        }
      }

      let type: String
      let jsonSchema: JSONSchema

      enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
      }
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int
    let reasoningEffort: String
    let responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
      case model, messages, temperature
      case maxTokens = "max_tokens"
      case reasoningEffort = "reasoning_effort"
      case responseFormat = "response_format"
    }
  }

  func chunks(for transcript: SessionTranscript, tokenBudget: Int) throws -> [Chunk] {
    guard tokenBudget > 0 else {
      throw LMStudioError.invalidEndpoint("chunk token budget must be positive")
    }
    var result: [Chunk] = []
    var current: [SessionTranscript.Segment] = []
    var currentTokens = 0

    for segment in transcript.segments {
      let tokens = estimateTokens(for: segment)
      guard tokens <= tokenBudget else {
        throw LMStudioError.tokenBudgetExceeded(segmentID: segment.id)
      }
      if !current.isEmpty, currentTokens + tokens > tokenBudget {
        result.append(.init(index: result.count, segments: current, estimatedTokens: currentTokens))
        current = []
        currentTokens = 0
      }
      current.append(segment)
      currentTokens += tokens
    }
    if !current.isEmpty {
      result.append(.init(index: result.count, segments: current, estimatedTokens: currentTokens))
    }
    return result
  }

  func extractionRequest(modelID: String, chunk: Chunk, rawNotes: RawMeetingNotes) throws -> Data {
    let notes = rawNotes.notes.map { "[\($0.id)] @\($0.capturedAtMS)ms \($0.text)" }.joined(
      separator: "\n")
    let transcript = chunk.segments.map { "[\($0.id)] \($0.speaker): \($0.text)" }.joined(
      separator: "\n")
    let prompt = """
      Create an evidence-grounded partial meeting brief for transcript chunk \(chunk.index + 1). Use only supplied transcript and raw notes. Preserve the meeting language. Do not invent facts, timestamps, owners, or due dates. Every item must cite one or more `evidence_segment_ids` from the supplied transcript IDs only. Unknown owner and due date must be null. Return JSON matching the schema exactly.

      RAW NOTES (frozen revision \(rawNotes.revision)):
      \(notes)

      CANONICAL TRANSCRIPT SEGMENTS:
      \(transcript)
      """
    return try encodeRequest(
      modelID: modelID,
      prompt: prompt,
      schemaName: "quill_chunk_brief",
      allowedEvidenceIDs: chunk.segments.map(\.id)
    )
  }

  func reductionRequest(
    modelID: String, partials: [BriefResponseDecoder.ModelBriefPayload], rawNotes: RawMeetingNotes
  ) throws -> Data {
    let partialData = try JSONEncoder().encode(partials)
    let partialJSON = String(decoding: partialData, as: UTF8.self)
    let notes = rawNotes.notes.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n")
    let prompt = """
      Reduce the supplied evidence-grounded partial briefs into one concise meeting brief. Use only their claims and evidence IDs; do not invent information. Keep every item evidence-backed, retain only stable segment IDs, and use null for unknown owner or due date. Treat partial item IDs as opaque labels, and generate unique item IDs within the returned brief. Return JSON matching the schema exactly.

      RAW NOTES:
      \(notes)

      PARTIAL BRIEFS:
      \(partialJSON)
      """
    let allowedEvidenceIDs = partials.flatMap { partial in
      (partial.topics + partial.decisions + partial.openQuestions).flatMap(\.evidenceSegmentIDs)
        + partial.actionItems.flatMap(\.evidenceSegmentIDs)
    }
    return try encodeRequest(
      modelID: modelID,
      prompt: prompt,
      schemaName: "quill_meeting_brief",
      allowedEvidenceIDs: allowedEvidenceIDs
    )
  }

  /// Keeps each reduction request within a deterministic local budget. The
  /// reducer gets twice the extraction budget because partial JSON carries
  /// structured labels in addition to transcript-derived prose.
  func reductionBatches(
    for partials: [BriefResponseDecoder.ModelBriefPayload],
    tokenBudget: Int
  ) throws -> [[BriefResponseDecoder.ModelBriefPayload]] {
    guard tokenBudget > 0 else {
      throw LMStudioError.invalidEndpoint("reduction token budget must be positive")
    }
    let reductionBudget = tokenBudget > Int.max / 2 ? Int.max : tokenBudget * 2
    var batches: [[BriefResponseDecoder.ModelBriefPayload]] = []
    var current: [BriefResponseDecoder.ModelBriefPayload] = []
    var currentTokens = 0

    for partial in partials {
      let tokens = estimateTokens(for: partial)
      guard tokens <= reductionBudget else {
        throw LMStudioError.tokenBudgetExceeded(segmentID: "generated-partial")
      }
      if !current.isEmpty, currentTokens + tokens > reductionBudget {
        batches.append(current)
        current = []
        currentTokens = 0
      }
      current.append(partial)
      currentTokens += tokens
    }
    if !current.isEmpty { batches.append(current) }
    return batches
  }

  /// Model item IDs are not canonical identifiers. Scope them before they
  /// enter another reduction layer (and once more for the final artifact),
  /// so repeated `decision-1` labels from independent chunks cannot make a
  /// valid evidence-backed brief fail structural validation.
  func namespaced(
    _ payload: BriefResponseDecoder.ModelBriefPayload,
    namespace: String
  ) -> BriefResponseDecoder.ModelBriefPayload {
    func item(_ item: BriefResponseDecoder.ModelBriefPayload.Item, kind: String, index: Int)
      -> BriefResponseDecoder.ModelBriefPayload.Item
    {
      .init(
        id: "\(namespace)-\(kind)-\(index + 1)", text: item.text,
        evidenceSegmentIDs: item.evidenceSegmentIDs)
    }
    func action(_ item: BriefResponseDecoder.ModelBriefPayload.Action, index: Int)
      -> BriefResponseDecoder.ModelBriefPayload.Action
    {
      .init(
        id: "\(namespace)-action-\(index + 1)", text: item.text, owner: item.owner,
        dueDate: item.dueDate, evidenceSegmentIDs: item.evidenceSegmentIDs)
    }
    return .init(
      language: payload.language,
      overview: payload.overview,
      topics: payload.topics.enumerated().map { item($0.element, kind: "topic", index: $0.offset) },
      decisions: payload.decisions.enumerated().map {
        item($0.element, kind: "decision", index: $0.offset)
      },
      actionItems: payload.actionItems.enumerated().map { action($0.element, index: $0.offset) },
      openQuestions: payload.openQuestions.enumerated().map {
        item($0.element, kind: "question", index: $0.offset)
      },
      warnings: payload.warnings
    )
  }

  private func encodeRequest(
    modelID: String,
    prompt: String,
    schemaName: String,
    allowedEvidenceIDs: [String]
  ) throws -> Data {
    let request = ChatRequest(
      model: modelID,
      messages: [
        .init(
          role: "system",
          content:
            "You are a local-only meeting brief formatter. Output valid JSON and no prose outside JSON."
        ),
        .init(role: "user", content: prompt),
      ],
      temperature: 0,
      // Meeting extraction is a bounded formatting task. Gemma 4 enables
      // thinking by default; with a small local context it can spend the
      // entire completion budget in reasoning_content and return empty
      // assistant content. Disable reasoning so the constrained JSON is the
      // actual completion, and cap output to keep every request bounded.
      maxTokens: 2_048,
      reasoningEffort: "none",
      responseFormat: .init(
        type: "json_schema",
        jsonSchema: .init(
          name: schemaName,
          strict: true,
          schema: BriefResponseDecoder.jsonSchema(allowedEvidenceIDs: allowedEvidenceIDs)
        ))
    )
    return try JSONEncoder().encode(request)
  }

  private func estimateTokens(for segment: SessionTranscript.Segment) -> Int {
    // Conservative and deterministic. This is a budget guard, not a model
    // tokenizer claim, and never splits a canonical transcript segment.
    let characters =
      segment.id.unicodeScalars.count + segment.speaker.unicodeScalars.count
      + segment.text.unicodeScalars.count
    return max(1, (characters + 3) / 4) + 12
  }

  private func estimateTokens(for payload: BriefResponseDecoder.ModelBriefPayload) -> Int {
    var characters = payload.language.unicodeScalars.count + payload.overview.unicodeScalars.count
    var objects = 0
    for item in payload.topics + payload.decisions + payload.openQuestions {
      characters += item.id.unicodeScalars.count + item.text.unicodeScalars.count
      characters += item.evidenceSegmentIDs.reduce(0) { $0 + $1.unicodeScalars.count }
      objects += 1
    }
    for item in payload.actionItems {
      characters += item.id.unicodeScalars.count + item.text.unicodeScalars.count
      characters +=
        (item.owner?.unicodeScalars.count ?? 0) + (item.dueDate?.unicodeScalars.count ?? 0)
      characters += item.evidenceSegmentIDs.reduce(0) { $0 + $1.unicodeScalars.count }
      objects += 1
    }
    characters += payload.warnings.reduce(0) { $0 + $1.unicodeScalars.count }
    return max(1, (characters + 3) / 4) + objects * 8 + 16
  }
}

/// Minimal JSON value for embedding JSON Schema without string interpolation.
indirect enum JSONValue: Encodable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case integer(Int)
  case boolean(Bool)

  func encode(to encoder: Encoder) throws {
    switch self {
    case .object(let value): try value.encode(to: encoder)
    case .array(let value): try value.encode(to: encoder)
    case .string(let value): try value.encode(to: encoder)
    case .integer(let value): try value.encode(to: encoder)
    case .boolean(let value): try value.encode(to: encoder)
    }
  }
}
