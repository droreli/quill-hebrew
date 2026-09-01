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
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    func decodePayload(from responseData: Data) throws -> ModelBriefPayload {
        do {
            let envelope = try JSONDecoder().decode(OpenAIEnvelope.self, from: responseData)
            guard let content = envelope.choices.first?.message.content,
                  let contentData = content.data(using: .utf8) else {
                throw LMStudioError.malformedResponse
            }
            return try JSONDecoder().decode(ModelBriefPayload.self, from: contentData)
        } catch let error as LMStudioError {
            throw error
        } catch {
            throw LMStudioError.malformedResponse
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
        let topics = try payload.topics.map { try BriefItem(id: $0.id, text: $0.text, evidence: evidence($0.evidenceSegmentIDs)) }
        let decisions = try payload.decisions.map { try BriefItem(id: $0.id, text: $0.text, evidence: evidence($0.evidenceSegmentIDs)) }
        let actions = try payload.actionItems.map { try ActionItem(id: $0.id, text: $0.text, owner: $0.owner, dueDate: $0.dueDate, evidence: evidence($0.evidenceSegmentIDs)) }
        let questions = try payload.openQuestions.map { try BriefItem(id: $0.id, text: $0.text, evidence: evidence($0.evidenceSegmentIDs)) }
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
            topics: topics,
            decisions: decisions,
            actionItems: actions,
            openQuestions: questions,
            warnings: payload.warnings
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

    static let jsonSchema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "required": .array([.string("language"), .string("overview"), .string("topics"), .string("decisions"), .string("action_items"), .string("open_questions"), .string("warnings")]),
        "properties": .object([
            "language": .object(["type": .string("string")]),
            "overview": .object(["type": .string("string")]),
            "topics": itemArraySchema,
            "decisions": itemArraySchema,
            "action_items": actionArraySchema,
            "open_questions": itemArraySchema,
            "warnings": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
        ]),
    ])

    private static let itemArraySchema: JSONValue = .object([
        "type": .string("array"),
        "items": .object([
            "type": .string("object"), "additionalProperties": .boolean(false),
            "required": .array([.string("id"), .string("text"), .string("evidence_segment_ids")]),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "text": .object(["type": .string("string")]),
                "evidence_segment_ids": .object(["type": .string("array"), "minItems": .integer(1), "items": .object(["type": .string("string")])]),
            ]),
        ]),
    ])

    private static let actionArraySchema: JSONValue = .object([
        "type": .string("array"),
        "items": .object([
            "type": .string("object"), "additionalProperties": .boolean(false),
            "required": .array([.string("id"), .string("text"), .string("owner"), .string("due_date"), .string("evidence_segment_ids")]),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "text": .object(["type": .string("string")]),
                "owner": .object(["type": .array([.string("string"), .string("null")])]),
                "due_date": .object(["type": .array([.string("string"), .string("null")])]),
                "evidence_segment_ids": .object(["type": .string("array"), "minItems": .integer(1), "items": .object(["type": .string("string")])]),
            ]),
        ]),
    ])
}
