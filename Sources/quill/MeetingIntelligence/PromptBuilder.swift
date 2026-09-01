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
        let responseFormat: ResponseFormat

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case responseFormat = "response_format"
        }
    }

    func chunks(for transcript: SessionTranscript, tokenBudget: Int) throws -> [Chunk] {
        guard tokenBudget > 0 else { throw LMStudioError.invalidEndpoint("chunk token budget must be positive") }
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
        let notes = rawNotes.notes.map { "[\($0.id)] @\($0.capturedAtMS)ms \($0.text)" }.joined(separator: "\n")
        let transcript = chunk.segments.map { "[\($0.id)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
        let prompt = """
        Create an evidence-grounded partial meeting brief for transcript chunk \(chunk.index + 1). Use only supplied transcript and raw notes. Preserve the meeting language. Do not invent facts, timestamps, owners, or due dates. Every item must cite one or more `evidence_segment_ids` from the supplied transcript IDs only. Unknown owner and due date must be null. Return JSON matching the schema exactly.

        RAW NOTES (frozen revision \(rawNotes.revision)):
        \(notes)

        CANONICAL TRANSCRIPT SEGMENTS:
        \(transcript)
        """
        return try encodeRequest(modelID: modelID, prompt: prompt, schemaName: "quill_chunk_brief")
    }

    func reductionRequest(modelID: String, partials: [BriefResponseDecoder.ModelBriefPayload], rawNotes: RawMeetingNotes) throws -> Data {
        let partialData = try JSONEncoder().encode(partials)
        let partialJSON = String(decoding: partialData, as: UTF8.self)
        let notes = rawNotes.notes.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n")
        let prompt = """
        Reduce the supplied evidence-grounded partial briefs into one concise meeting brief. Use only their claims and evidence IDs; do not invent information. Keep every item evidence-backed, retain only stable segment IDs, and use null for unknown owner or due date. Return JSON matching the schema exactly.

        RAW NOTES:
        \(notes)

        PARTIAL BRIEFS:
        \(partialJSON)
        """
        return try encodeRequest(modelID: modelID, prompt: prompt, schemaName: "quill_meeting_brief")
    }

    private func encodeRequest(modelID: String, prompt: String, schemaName: String) throws -> Data {
        let request = ChatRequest(
            model: modelID,
            messages: [
                .init(role: "system", content: "You are a local-only meeting brief formatter. Output valid JSON and no prose outside JSON."),
                .init(role: "user", content: prompt),
            ],
            temperature: 0,
            responseFormat: .init(type: "json_schema", jsonSchema: .init(name: schemaName, strict: true, schema: BriefResponseDecoder.jsonSchema))
        )
        return try JSONEncoder().encode(request)
    }

    private func estimateTokens(for segment: SessionTranscript.Segment) -> Int {
        // Conservative and deterministic. This is a budget guard, not a model
        // tokenizer claim, and never splits a canonical transcript segment.
        let characters = segment.id.unicodeScalars.count + segment.speaker.unicodeScalars.count + segment.text.unicodeScalars.count
        return max(1, (characters + 3) / 4) + 12
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
        case let .object(value): try value.encode(to: encoder)
        case let .array(value): try value.encode(to: encoder)
        case let .string(value): try value.encode(to: encoder)
        case let .integer(value): try value.encode(to: encoder)
        case let .boolean(value): try value.encode(to: encoder)
        }
    }
}
