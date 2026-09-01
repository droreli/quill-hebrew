import Foundation

/// Versioned, local-only contracts for post-transcript meeting intelligence.
/// These types deliberately do not own recording, audio, or transcription.
enum MeetingIntelligenceSchema {
    static let transcriptV1 = "quill.transcript.v1"
    static let rawNotesV1 = "quill.raw-notes.v1"
    static let meetingBriefV1 = "quill.meeting-brief.v1"
}

enum MeetingIntelligenceContractError: Error, Equatable, LocalizedError {
    case unsupportedSchema(String)
    case invalidRange(context: String)
    case duplicateIdentifier(context: String, id: String)
    case invalidRevision(Int)
    case unknownEvidenceSegment(String)
    case invalidEvidence(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version): "Unsupported meeting-intelligence schema version: \(version)"
        case let .invalidRange(context): "Invalid non-negative ordered range for \(context)"
        case let .duplicateIdentifier(context, id): "Duplicate \(context) identifier: \(id)"
        case let .invalidRevision(revision): "Raw-notes revision must be non-negative, got \(revision)"
        case let .unknownEvidenceSegment(id): "Evidence references unknown transcript segment: \(id)"
        case let .invalidEvidence(message): "Invalid evidence: \(message)"
        }
    }
}

/// Evidence links locate source material; they do not prove generated prose.
/// Every human-readable claim carries a support state so it cannot be shown as
/// verified merely because it cites a real transcript segment.
enum BriefClaimSupport: String, Codable, Sendable, Equatable {
    case aiGeneratedRequiresReview = "ai_generated_requires_review"
    case quillSystemNotice = "quill_system_notice"
}

/// Canonical representation of a transcript on disk. Current transcripts do
/// not have a schema version or segment IDs; both remain readable.
struct SessionTranscript: Codable, Sendable, Equatable {
    struct Segment: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let speaker: String
        let startMS: Int
        let endMS: Int
        let text: String

        enum CodingKeys: String, CodingKey {
            case id
            case speaker
            case startMS = "start_ms"
            case endMS = "end_ms"
            case text
        }

        init(id: String, speaker: String, startMS: Int, endMS: Int, text: String) {
            self.id = id
            self.speaker = speaker
            self.startMS = startMS
            self.endMS = endMS
            self.text = text
        }
    }

    let schemaVersion: String?
    let engine: String
    let model: String
    let createdAt: String
    let speakerLabels: Bool
    let timestamps: Bool
    let segments: [Segment]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case engine, model
        case createdAt = "created_at"
        case speakerLabels = "speaker_labels"
        case timestamps, segments
    }

    init(
        schemaVersion: String? = MeetingIntelligenceSchema.transcriptV1,
        engine: String,
        model: String,
        createdAt: String,
        speakerLabels: Bool,
        timestamps: Bool,
        segments: [Segment]
    ) throws {
        self.schemaVersion = schemaVersion
        self.engine = engine
        self.model = model
        self.createdAt = createdAt
        self.speakerLabels = speakerLabels
        self.timestamps = timestamps
        self.segments = segments
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
        let engine = try container.decode(String.self, forKey: .engine)
        let model = try container.decode(String.self, forKey: .model)
        let createdAt = try container.decode(String.self, forKey: .createdAt)
        let speakerLabels = try container.decode(Bool.self, forKey: .speakerLabels)
        let timestamps = try container.decode(Bool.self, forKey: .timestamps)
        let decodedSegments = try container.decode([Segment].self, forKey: .segments)

        self.schemaVersion = schemaVersion
        self.engine = engine
        self.model = model
        self.createdAt = createdAt
        self.speakerLabels = speakerLabels
        self.timestamps = timestamps
        self.segments = decodedSegments.enumerated().map { index, segment in
            segment.id.isEmpty
                ? Segment(id: Self.stableSegmentID(for: index), speaker: segment.speaker, startMS: segment.startMS, endMS: segment.endMS, text: segment.text)
                : segment
        }
        try validate()
    }

    /// `s000001`, `s000002`, ...; array order is the stable legacy source.
    static func stableSegmentID(for index: Int) -> String {
        String(format: "s%06d", index + 1)
    }

    func validate() throws {
        if let schemaVersion, schemaVersion != MeetingIntelligenceSchema.transcriptV1 {
            throw MeetingIntelligenceContractError.unsupportedSchema(schemaVersion)
        }
        var knownIDs = Set<String>()
        for segment in segments {
            guard segment.startMS >= 0, segment.endMS >= segment.startMS else {
                throw MeetingIntelligenceContractError.invalidRange(context: "transcript segment \(segment.id)")
            }
            guard knownIDs.insert(segment.id).inserted else {
                throw MeetingIntelligenceContractError.duplicateIdentifier(context: "transcript segment", id: segment.id)
            }
        }
    }

    var segmentsByID: [String: Segment] {
        Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
    }
}

extension SessionTranscript.Segment {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        speaker = try container.decode(String.self, forKey: .speaker)
        startMS = try container.decode(Int.self, forKey: .startMS)
        endMS = try container.decode(Int.self, forKey: .endMS)
        text = try container.decode(String.self, forKey: .text)
    }
}

struct RawMeetingNotes: Codable, Sendable, Equatable {
    struct Note: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let text: String
        let capturedAtMS: Int
        let createdAt: String
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case id, text
            case capturedAtMS = "captured_at_ms"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    let schemaVersion: String
    let sessionID: String
    let revision: Int
    let template: String
    let updatedAt: String
    let notes: [Note]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case revision, template
        case updatedAt = "updated_at"
        case notes
    }

    init(schemaVersion: String = MeetingIntelligenceSchema.rawNotesV1, sessionID: String, revision: Int, template: String, updatedAt: String, notes: [Note]) throws {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.revision = revision
        self.template = template
        self.updatedAt = updatedAt
        self.notes = notes
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        revision = try container.decode(Int.self, forKey: .revision)
        template = try container.decode(String.self, forKey: .template)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        notes = try container.decode([Note].self, forKey: .notes)
        try validate()
    }

    func validate() throws {
        guard schemaVersion == MeetingIntelligenceSchema.rawNotesV1 else {
            throw MeetingIntelligenceContractError.unsupportedSchema(schemaVersion)
        }
        guard revision >= 0 else { throw MeetingIntelligenceContractError.invalidRevision(revision) }
        var knownIDs = Set<String>()
        for note in notes {
            guard note.capturedAtMS >= 0 else {
                throw MeetingIntelligenceContractError.invalidRange(context: "raw note \(note.id)")
            }
            guard knownIDs.insert(note.id).inserted else {
                throw MeetingIntelligenceContractError.duplicateIdentifier(context: "raw note", id: note.id)
            }
        }
    }
}

struct EvidenceReference: Codable, Sendable, Equatable {
    let segmentID: String
    let transcriptJSONPointer: String
    let startMS: Int
    let endMS: Int
    let speaker: String

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case transcriptJSONPointer = "transcript_json_pointer"
        case startMS = "start_ms"
        case endMS = "end_ms"
        case speaker
    }

    init(segmentID: String, transcriptJSONPointer: String, startMS: Int, endMS: Int, speaker: String) throws {
        self.segmentID = segmentID
        self.transcriptJSONPointer = transcriptJSONPointer
        self.startMS = startMS
        self.endMS = endMS
        self.speaker = speaker
        try validateRange()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segmentID = try container.decode(String.self, forKey: .segmentID)
        transcriptJSONPointer = try container.decode(String.self, forKey: .transcriptJSONPointer)
        startMS = try container.decode(Int.self, forKey: .startMS)
        endMS = try container.decode(Int.self, forKey: .endMS)
        speaker = try container.decode(String.self, forKey: .speaker)
        try validateRange()
    }

    func validateRange() throws {
        guard startMS >= 0, endMS >= startMS else {
            throw MeetingIntelligenceContractError.invalidRange(context: "evidence \(segmentID)")
        }
    }
}

struct BriefItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let text: String
    let evidence: [EvidenceReference]
    let support: BriefClaimSupport

    init(
        id: String,
        text: String,
        evidence: [EvidenceReference],
        support: BriefClaimSupport = .aiGeneratedRequiresReview
    ) {
        self.id = id
        self.text = text
        self.evidence = evidence
        self.support = support
    }

    enum CodingKeys: String, CodingKey { case id, text, evidence, support }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        evidence = try container.decode([EvidenceReference].self, forKey: .evidence)
        // Legacy artifacts did not express this boundary; read them
        // conservatively as AI-generated material requiring review.
        support = try container.decodeIfPresent(BriefClaimSupport.self, forKey: .support) ?? .aiGeneratedRequiresReview
    }
}

struct ActionItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let text: String
    let owner: String?
    let dueDate: String?
    let evidence: [EvidenceReference]
    let support: BriefClaimSupport

    enum CodingKeys: String, CodingKey {
        case id, text, owner, evidence, support
        case dueDate = "due_date"
    }

    init(
        id: String,
        text: String,
        owner: String?,
        dueDate: String?,
        evidence: [EvidenceReference],
        support: BriefClaimSupport = .aiGeneratedRequiresReview
    ) {
        self.id = id
        self.text = text
        self.owner = owner
        self.dueDate = dueDate
        self.evidence = evidence
        self.support = support
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        dueDate = try container.decodeIfPresent(String.self, forKey: .dueDate)
        evidence = try container.decode([EvidenceReference].self, forKey: .evidence)
        support = try container.decodeIfPresent(BriefClaimSupport.self, forKey: .support) ?? .aiGeneratedRequiresReview
    }
}

struct SummaryInput: Codable, Sendable, Equatable {
    let transcriptSHA256: String
    let transcriptSegmentCount: Int
    let rawNotesRevision: Int
    /// Optional only for legacy artifacts. New jobs always persist this digest.
    let rawNotesSHA256: String?

    enum CodingKeys: String, CodingKey {
        case transcriptSHA256 = "transcript_sha256"
        case transcriptSegmentCount = "transcript_segment_count"
        case rawNotesRevision = "raw_notes_revision"
        case rawNotesSHA256 = "raw_notes_sha256"
    }

    init(
        transcriptSHA256: String,
        transcriptSegmentCount: Int,
        rawNotesRevision: Int,
        rawNotesSHA256: String? = nil
    ) {
        self.transcriptSHA256 = transcriptSHA256
        self.transcriptSegmentCount = transcriptSegmentCount
        self.rawNotesRevision = rawNotesRevision
        self.rawNotesSHA256 = rawNotesSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcriptSHA256 = try container.decode(String.self, forKey: .transcriptSHA256)
        transcriptSegmentCount = try container.decode(Int.self, forKey: .transcriptSegmentCount)
        rawNotesRevision = try container.decode(Int.self, forKey: .rawNotesRevision)
        rawNotesSHA256 = try container.decodeIfPresent(String.self, forKey: .rawNotesSHA256)
    }
}

struct GenerationProvenance: Codable, Sendable, Equatable {
    let engine: String
    let endpoint: String?
    let runtimeVersion: String
    let modelID: String
    let modelRevision: String?
    let quantization: String
    let localOnly: Bool
    let provenance: String

    enum CodingKeys: String, CodingKey {
        case engine
        case endpoint
        case runtimeVersion = "runtime_version"
        case modelID = "model_id"
        case modelRevision = "model_revision"
        case quantization
        case localOnly = "local_only"
        case provenance
    }

    init(engine: String, endpoint: String? = nil, runtimeVersion: String, modelID: String, modelRevision: String?, quantization: String, localOnly: Bool, provenance: String) throws {
        self.engine = engine
        self.endpoint = endpoint
        self.runtimeVersion = runtimeVersion
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.quantization = quantization
        self.localOnly = localOnly
        self.provenance = provenance
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engine = try container.decode(String.self, forKey: .engine)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        runtimeVersion = try container.decode(String.self, forKey: .runtimeVersion)
        modelID = try container.decode(String.self, forKey: .modelID)
        modelRevision = try container.decodeIfPresent(String.self, forKey: .modelRevision)
        quantization = try container.decode(String.self, forKey: .quantization)
        localOnly = try container.decode(Bool.self, forKey: .localOnly)
        provenance = try container.decode(String.self, forKey: .provenance)
        try validate()
    }

    func validate() throws {
        guard localOnly else {
            throw MeetingIntelligenceContractError.invalidEvidence("generator provenance must be local_only")
        }
        guard let endpoint else { return }
        guard (try? LMStudioConfiguration.validateLoopbackEndpoint(endpoint)) != nil else {
            throw MeetingIntelligenceContractError.invalidEvidence("generator endpoint must be a literal HTTP loopback address")
        }
    }
}

struct MeetingBrief: Codable, Sendable, Equatable, Identifiable {
    let schemaVersion: String
    let id: String
    let createdAt: String
    let language: String
    let inputs: SummaryInput
    let generator: GenerationProvenance
    let overview: String
    let overviewSupport: BriefClaimSupport
    let topics: [BriefItem]
    let decisions: [BriefItem]
    let actionItems: [ActionItem]
    let openQuestions: [BriefItem]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case createdAt = "created_at"
        case language, inputs, generator, overview
        case overviewSupport = "overview_support"
        case topics, decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
        case warnings
    }

    static let requiredReviewWarning = "AI-generated draft: review every claim against the transcript before relying on it. Evidence links are navigation aids, not verification."

    init(schemaVersion: String = MeetingIntelligenceSchema.meetingBriefV1, id: String, createdAt: String, language: String, inputs: SummaryInput, generator: GenerationProvenance, overview: String, overviewSupport: BriefClaimSupport = .aiGeneratedRequiresReview, topics: [BriefItem], decisions: [BriefItem], actionItems: [ActionItem], openQuestions: [BriefItem], warnings: [String]) throws {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.language = language
        self.inputs = inputs
        self.generator = generator
        self.overview = overview
        self.overviewSupport = overviewSupport
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.warnings = Self.withRequiredReviewWarning(warnings)
        try validateStructure()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        language = try container.decode(String.self, forKey: .language)
        inputs = try container.decode(SummaryInput.self, forKey: .inputs)
        generator = try container.decode(GenerationProvenance.self, forKey: .generator)
        overview = try container.decode(String.self, forKey: .overview)
        overviewSupport = try container.decodeIfPresent(BriefClaimSupport.self, forKey: .overviewSupport) ?? .aiGeneratedRequiresReview
        topics = try container.decode([BriefItem].self, forKey: .topics)
        decisions = try container.decode([BriefItem].self, forKey: .decisions)
        actionItems = try container.decode([ActionItem].self, forKey: .actionItems)
        openQuestions = try container.decode([BriefItem].self, forKey: .openQuestions)
        warnings = Self.withRequiredReviewWarning(try container.decode([String].self, forKey: .warnings))
        try validateStructure()
    }

    func validateStructure() throws {
        guard schemaVersion == MeetingIntelligenceSchema.meetingBriefV1 else {
            throw MeetingIntelligenceContractError.unsupportedSchema(schemaVersion)
        }
        guard inputs.transcriptSegmentCount >= 0, inputs.rawNotesRevision >= 0,
              inputs.rawNotesSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            throw MeetingIntelligenceContractError.invalidRange(context: "brief inputs")
        }
        try generator.validate()
        let ids = topics.map(\.id) + decisions.map(\.id) + actionItems.map(\.id) + openQuestions.map(\.id)
        var knownIDs = Set<String>()
        for id in ids where !knownIDs.insert(id).inserted {
            throw MeetingIntelligenceContractError.duplicateIdentifier(context: "brief item", id: id)
        }
        for item in topics + decisions + openQuestions {
            try validate(item: item)
        }
        for item in actionItems {
            guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.evidence.isEmpty else {
                throw MeetingIntelligenceContractError.invalidEvidence("structured brief items must be non-empty and cited")
            }
        }
        guard warnings.contains(Self.requiredReviewWarning) else {
            throw MeetingIntelligenceContractError.invalidEvidence("brief must include the mandatory AI-review warning")
        }
        for evidence in allEvidence { try evidence.validateRange() }
    }

    /// Checks all brief references against the immutable canonical transcript.
    func validateEvidence(against transcript: SessionTranscript) throws {
        try validateStructure()
        let segments = transcript.segmentsByID
        for evidence in allEvidence {
            guard let segment = segments[evidence.segmentID] else {
                throw MeetingIntelligenceContractError.unknownEvidenceSegment(evidence.segmentID)
            }
            guard evidence.startMS == segment.startMS,
                  evidence.endMS == segment.endMS,
                  evidence.speaker == segment.speaker,
                  evidence.transcriptJSONPointer == "/segments/\(transcript.segments.firstIndex(where: { $0.id == evidence.segmentID })!)"
            else {
                throw MeetingIntelligenceContractError.invalidEvidence("metadata for \(evidence.segmentID) does not match transcript")
            }
        }
    }

    private var allEvidence: [EvidenceReference] {
        topics.flatMap(\.evidence)
            + decisions.flatMap(\.evidence)
            + actionItems.flatMap(\.evidence)
            + openQuestions.flatMap(\.evidence)
    }

    private static func withRequiredReviewWarning(_ warnings: [String]) -> [String] {
        warnings.contains(requiredReviewWarning) ? warnings : [requiredReviewWarning] + warnings
    }

    private func validate(item: BriefItem) throws {
        guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !item.evidence.isEmpty else {
            throw MeetingIntelligenceContractError.invalidEvidence("structured brief items must be non-empty and cited")
        }
    }

    static func incompleteTranscript(input: SummaryInput, createdAt: String = ISO8601DateFormatter().string(from: Date())) throws -> MeetingBrief {
        try MeetingBrief(
            id: UUID().uuidString,
            createdAt: createdAt,
            language: "undetermined",
            inputs: input,
            generator: .init(engine: "quill-pipeline", runtimeVersion: "quill", modelID: "none", modelRevision: nil, quantization: "none", localOnly: true, provenance: "quill-owned coverage check"),
            overview: "No transcript segments are available, so no AI summary was requested.",
            overviewSupport: .quillSystemNotice,
            topics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            warnings: ["Transcript coverage is incomplete: the transcript contains zero segments. Generate a brief only after transcription produces canonical segments."]
        )
    }
}

/// Implemented by fully-local model adapters. The pipeline owns scheduling,
/// cancellation, persistence, and validation around this boundary.
protocol SummarizationEngine: Sendable {
    func summarize(
        transcript: SessionTranscript,
        rawNotes: RawMeetingNotes,
        input: SummaryInput
    ) async throws -> MeetingBrief
}
