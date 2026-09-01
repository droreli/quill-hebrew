import Foundation
import Testing
@testable import quill

@Test func currentTranscriptFixturesDecodeWithDeterministicIDs() throws {
    for name in ["transcript-hebrew", "transcript-english", "transcript-mixed"] {
        let transcript = try TranscriptReader().readTranscript(at: fixtureURL(name))
        #expect(transcript.schemaVersion == nil)
        #expect(transcript.segments.map(\.id) == ["s000001", "s000002"])
        #expect(transcript.segments.count == 2)
    }
}

@Test func transcriptRetainsHebrewEnglishAndMixedText() throws {
    let hebrew = try TranscriptReader().readTranscript(at: fixtureURL("transcript-hebrew"))
    let english = try TranscriptReader().readTranscript(at: fixtureURL("transcript-english"))
    let mixed = try TranscriptReader().readTranscript(at: fixtureURL("transcript-mixed"))

    #expect(hebrew.segments[0].text.contains("פיילוט"))
    #expect(english.segments[0].text.contains("two-week"))
    #expect(mixed.segments[0].text.contains("API"))
    #expect(mixed.segments[1].text.contains("$4,000"))
}

@Test func unsupportedAndInvalidTranscriptSchemasAreRejected() {
    #expect(throws: MeetingIntelligenceContractError.self) {
        try SessionTranscript(
            schemaVersion: "quill.transcript.v99",
            engine: "engine",
            model: "model",
            createdAt: "2026-09-01T00:00:00Z",
            speakerLabels: true,
            timestamps: true,
            segments: []
        )
    }
    #expect(throws: MeetingIntelligenceContractError.self) {
        try SessionTranscript(
            engine: "engine",
            model: "model",
            createdAt: "2026-09-01T00:00:00Z",
            speakerLabels: true,
            timestamps: true,
            segments: [.init(id: "s000001", speaker: "me", startMS: 20, endMS: 10, text: "bad")]
        )
    }
}

@Test func rawNotesRoundTripAndRejectsDuplicateIDs() throws {
    let note = RawMeetingNotes.Note(
        id: "note-1",
        text: "# החלטות\n- Dana: send proposal",
        capturedAtMS: 542_000,
        createdAt: "2026-09-01T10:00:00Z",
        updatedAt: "2026-09-01T10:00:00Z"
    )
    let notes = try RawMeetingNotes(
        sessionID: "session-1",
        revision: 12,
        template: "general",
        updatedAt: "2026-09-01T10:00:00Z",
        notes: [note]
    )
    let encoded = try JSONEncoder().encode(notes)
    #expect(try JSONDecoder().decode(RawMeetingNotes.self, from: encoded) == notes)
    #expect(throws: MeetingIntelligenceContractError.self) {
        try RawMeetingNotes(
            sessionID: "session-1",
            revision: 1,
            template: "general",
            updatedAt: "2026-09-01T10:00:00Z",
            notes: [note, note]
        )
    }
}

@Test func meetingBriefRoundTripsAndRejectsUnknownEvidence() throws {
    let transcript = try TranscriptReader().readTranscript(at: fixtureURL("transcript-mixed"))
    let evidence = try EvidenceReference(
        segmentID: "s000001",
        transcriptJSONPointer: "/segments/0",
        startMS: 0,
        endMS: 2400,
        speaker: "me"
    )
    let brief = try MeetingBrief(
        id: "brief-1",
        createdAt: "2026-09-01T10:00:00Z",
        language: "mixed",
        inputs: .init(transcriptSHA256: "abc", transcriptSegmentCount: 2, rawNotesRevision: 12),
        generator: try .init(engine: "fake", runtimeVersion: "test", modelID: "fake", modelRevision: nil, quantization: "none", localOnly: true, provenance: "fixture"),
        overview: "Pilot proposal",
        topics: [.init(id: "topic-1", text: "Scope", evidence: [evidence])],
        decisions: [.init(id: "decision-1", text: "Pilot", evidence: [evidence])],
        actionItems: [.init(id: "action-1", text: "Send proposal", owner: "יעל", dueDate: nil, evidence: [evidence])],
        openQuestions: [],
        warnings: []
    )
    try brief.validateEvidence(against: transcript)
    #expect(try JSONDecoder().decode(MeetingBrief.self, from: JSONEncoder().encode(brief)) == brief)

    let unknown = try EvidenceReference(
        segmentID: "s999999",
        transcriptJSONPointer: "/segments/9",
        startMS: 0,
        endMS: 1,
        speaker: "me"
    )
    let invalid = try MeetingBrief(
        id: "brief-2",
        createdAt: "2026-09-01T10:00:00Z",
        language: "english",
        inputs: .init(transcriptSHA256: "abc", transcriptSegmentCount: 2, rawNotesRevision: 0),
        generator: try .init(engine: "fake", runtimeVersion: "test", modelID: "fake", modelRevision: nil, quantization: "none", localOnly: true, provenance: "fixture"),
        overview: "",
        topics: [.init(id: "topic-2", text: "Unknown", evidence: [unknown])],
        decisions: [],
        actionItems: [],
        openQuestions: [],
        warnings: []
    )
    #expect(throws: MeetingIntelligenceContractError.self) {
        try invalid.validateEvidence(against: transcript)
    }
}

@Test func generatorRequiresLocalOnlyAndLiteralLoopbackEndpoint() {
    #expect(throws: MeetingIntelligenceContractError.self) {
        try GenerationProvenance(
            engine: "remote",
            runtimeVersion: "1",
            modelID: "x",
            modelRevision: nil,
            quantization: "none",
            localOnly: false,
            provenance: "bad"
        )
    }
    for endpoint in ["https://example.com", "http://localhost:1234"] {
        #expect(throws: MeetingIntelligenceContractError.self) {
            try GenerationProvenance(
                engine: "remote",
                endpoint: endpoint,
                runtimeVersion: "1",
                modelID: "x",
                modelRevision: nil,
                quantization: "none",
                localOnly: true,
                provenance: "bad"
            )
        }
    }
    #expect(throws: Never.self) {
        try GenerationProvenance(
            engine: "lmstudio-openai",
            endpoint: "http://127.0.0.1:1234",
            runtimeVersion: "reported",
            modelID: "google/gemma-4-26b-a4b-qat",
            modelRevision: nil,
            quantization: "4-bit",
            localOnly: true,
            provenance: "reported"
        )
    }
}

private func fixtureURL(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
}
