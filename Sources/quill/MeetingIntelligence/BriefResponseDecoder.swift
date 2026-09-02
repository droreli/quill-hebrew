import Foundation

/// Decodes LM Studio's OpenAI-compatible envelope, then turns its intentionally
/// ID-only evidence into canonical transcript metadata. Model-provided timing,
/// speakers, and JSON pointers are never accepted.
struct BriefResponseDecoder: Sendable {
    struct ModelBriefPayload: Codable, Sendable, Equatable {
        struct Item: Codable, Sendable, Equatable {
            let id: String
            let text: String
            let evidenceSegmentIDs: [String]

            enum CodingKeys: String, CodingKey {
                case id, text
                case evidenceSegmentIDs = "evidence_segment_ids"
            }
        }

        struct Action: Codable, Sendable, Equatable {
            let id: String
            let text: String
            let owner: String?
            let dueDate: String?
            let evidenceSegmentIDs: [String]

            enum CodingKeys: String, CodingKey {
                case id, text, owner
                case dueDate = "due_date"
                case evidenceSegmentIDs = "evidence_segment_ids"
            }
        }

        let language: String
        let overview: String
        let topics: [Item]
        let decisions: [Item]
        let actionItems: [Action]
        let openQuestions: [Item]
        let warnings: [String]

        enum CodingKeys: String, CodingKey {
            case language, overview, topics, decisions, warnings
            case actionItems = "action_items"
            case openQuestions = "open_questions"
        }
    }

    private struct OpenAIEnvelope: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: StructuredContent?
                let reasoningContent: StructuredContent?

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                }
            }

            let message: Message?
            let text: StructuredContent?
        }
        let choices: [Choice]
    }

    /// LM Studio's OpenAI-compatible endpoint normally returns a string, but
    /// some local model/runtime combinations return typed content parts. Keep
    /// this boundary tolerant of those transport-only variants; the decoded
    /// payload and every evidence ID remain subject to the same strict checks.
    private enum StructuredContent: Decodable {
        struct Part: Decodable {
            let type: String?
            let text: String?
        }

        case string(String)
        case parts([Part])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
            self = .parts(try container.decode([Part].self))
        }

        var candidates: [String] {
            switch self {
            case let .string(value): return [value]
            case let .parts(parts):
                let text = parts.compactMap(\.text).joined(separator: "\n")
                return text.isEmpty ? [] : [text]
            }
        }
    }

    func decodePayload(from responseData: Data) throws -> ModelBriefPayload {
        do {
            let envelope = try JSONDecoder().decode(OpenAIEnvelope.self, from: responseData)
            guard let choice = envelope.choices.first else { throw LMStudioError.malformedResponse }
            let contentCandidates = (choice.message?.content?.candidates ?? [])
                // A few local runtimes place the final structured response in
                // reasoning_content. It is considered only if it independently
                // decodes as the full schema below.
                + (choice.message?.reasoningContent?.candidates ?? [])
                + (choice.text?.candidates ?? [])
            for content in contentCandidates {
                if let payload = decodePayloadContent(content) {
                    return payload
                }
            }
            throw LMStudioError.malformedResponse
        } catch let error as LMStudioError {
            throw error
        } catch {
            throw LMStudioError.malformedResponse
        }
    }

    private func decodePayloadContent(_ content: String) -> ModelBriefPayload? {
        for candidate in normalizedJSONCandidates(content) {
            guard let data = candidate.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ModelBriefPayload.self, from: data)
            else { continue }
            return payload
        }
        return nil
    }

    /// Normalizes formatting wrappers only. It never repairs, fills in, or
    /// infers model facts; a candidate must still decode as the complete
    /// schema before it can enter the evidence-validation path.
    private func normalizedJSONCandidates(_ content: String) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates = [trimmed]
        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3, let closing = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "```" }) {
                let body = lines[1..<closing].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { candidates.append(body) }
            }
        }
        // Some OpenAI-compatible proxies JSON-encode the content string one
        // extra time. Unwrap at most once so ordinary model text is never
        // repeatedly interpreted as executable or authoritative structure.
        if let data = trimmed.data(using: .utf8),
           let wrapped = try? JSONDecoder().decode(String.self, from: data) {
            candidates.append(wrapped.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return candidates.reduce(into: []) { result, candidate in
            if !result.contains(candidate) { result.append(candidate) }
        }
    }

    func validateEvidenceIDs(_ payload: ModelBriefPayload, against transcript: SessionTranscript) throws {
        let known = Set(transcript.segments.map(\.id))
        for item in payload.topics + payload.decisions + payload.openQuestions {
            try validate(item.id, evidenceIDs: item.evidenceSegmentIDs, known: known)
        }
        for item in payload.actionItems {
            try validate(item.id, evidenceIDs: item.evidenceSegmentIDs, known: known)
        }
    }

    func makeMeetingBrief(
        payload: ModelBriefPayload,
        transcript: SessionTranscript,
        input: SummaryInput,
        configuration: LMStudioConfiguration,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        id: String = UUID().uuidString
    ) throws -> MeetingBrief {
        try validateEvidenceIDs(payload, against: transcript)
        let indexByID = Dictionary(uniqueKeysWithValues: transcript.segments.enumerated().map { ($0.element.id, $0.offset) })
        let byID = transcript.segmentsByID
        func evidence(_ ids: [String]) throws -> [EvidenceReference] {
            try ids.map { segmentID in
                guard let segment = byID[segmentID], let index = indexByID[segmentID] else {
                    throw MeetingIntelligenceContractError.unknownEvidenceSegment(segmentID)
                }
                return try EvidenceReference(
                    segmentID: segmentID,
                    transcriptJSONPointer: "/segments/\(index)",
                    startMS: segment.startMS,
                    endMS: segment.endMS,
                    speaker: segment.speaker
                )
            }
        }
        let topics = try payload.topics.map { try BriefItem(id: $0.id, text: $0.text, evidence: evidence($0.evidenceSegmentIDs), support: .aiGeneratedRequiresReview) }
        let decisions = try payload.decisions.map { try BriefItem(id: $0.id, text: $0.text, evidence: evidence($0.evidenceSegmentIDs), support: .aiGeneratedRequiresReview) }
        let actions = try payload.actionItems.map { try ActionItem(id: $0.id, text: $0.text, owner: $0.owner, dueDate: $0.dueDate, evidence: evidence($0.evidenceSegmentIDs), support: .aiGeneratedRequiresReview) }
        let questions = try payload.openQuestions.map { try BriefItem(id: $0.id, text: $0.text, evidence: evidence($0.evidenceSegmentIDs), support: .aiGeneratedRequiresReview) }
        let generator = try GenerationProvenance(
            engine: "lmstudio-openai",
            endpoint: configuration.endpoint.absoluteString,
            runtimeVersion: "reported",
            modelID: configuration.modelID,
            modelRevision: nil,
            quantization: "reported",
            localOnly: true,
            provenance: "reported"
        )
        let brief = try MeetingBrief(
            id: id,
            createdAt: createdAt,
            language: payload.language,
            inputs: input,
            generator: generator,
            overview: payload.overview,
            overviewSupport: .aiGeneratedRequiresReview,
            topics: topics,
            decisions: decisions,
            actionItems: actions,
            openQuestions: questions,
            // Model warnings are free-form claims as well. Keep only Quill's
            // mandatory, deterministic review warning in the published brief.
            warnings: []
        )
        try brief.validateEvidence(against: transcript)
        return brief
    }

    private func validate(_ itemID: String, evidenceIDs: [String], known: Set<String>) throws {
        guard !itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !evidenceIDs.isEmpty else {
            throw LMStudioError.malformedResponse
        }
        for id in evidenceIDs where !known.contains(id) {
            throw MeetingIntelligenceContractError.unknownEvidenceSegment(id)
        }
    }

    static func jsonSchema(allowedEvidenceIDs: [String]) -> JSONValue {
        let evidenceIDSchema: JSONValue = .object([
            "type": .string("string"),
            "enum": .array(Array(Set(allowedEvidenceIDs)).sorted().map(JSONValue.string)),
        ])
        return .object([
            "type": .string("object"),
            "additionalProperties": .boolean(false),
            "required": .array([.string("language"), .string("overview"), .string("topics"), .string("decisions"), .string("action_items"), .string("open_questions"), .string("warnings")]),
            "properties": .object([
                "language": .object(["type": .string("string")]),
                "overview": .object(["type": .string("string")]),
                "topics": itemArraySchema(evidenceIDSchema: evidenceIDSchema),
                "decisions": itemArraySchema(evidenceIDSchema: evidenceIDSchema),
                "action_items": actionArraySchema(evidenceIDSchema: evidenceIDSchema),
                "open_questions": itemArraySchema(evidenceIDSchema: evidenceIDSchema),
                "warnings": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            ]),
        ])
    }

    private static func itemArraySchema(evidenceIDSchema: JSONValue) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": .object([
                "type": .string("object"), "additionalProperties": .boolean(false),
                "required": .array([.string("id"), .string("text"), .string("evidence_segment_ids")]),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "text": .object(["type": .string("string")]),
                    "evidence_segment_ids": .object(["type": .string("array"), "minItems": .integer(1), "items": evidenceIDSchema]),
                ]),
            ]),
        ])
    }

    private static func actionArraySchema(evidenceIDSchema: JSONValue) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": .object([
                "type": .string("object"), "additionalProperties": .boolean(false),
                "required": .array([.string("id"), .string("text"), .string("owner"), .string("due_date"), .string("evidence_segment_ids")]),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "text": .object(["type": .string("string")]),
                    "owner": .object(["type": .array([.string("string"), .string("null")])]),
                    "due_date": .object(["type": .array([.string("string"), .string("null")])]),
                    "evidence_segment_ids": .object(["type": .string("array"), "minItems": .integer(1), "items": evidenceIDSchema]),
                ]),
            ]),
        ])
    }
}
