import Foundation
import Testing

@testable import quill

@Test func qualityGateWithholdsRawNoteEchoesAndOverbroadUnassignedActions() throws {
    let transcript = try fixtureTranscript([
        ("s000001", "me", "We discussed a future proposal."),
        ("s000002", "them", "No one committed to send it."),
        ("s000003", "me", "The scope remains open."),
    ])
    let notes = try fixtureNotes(text: "Send the proposal to the client")
    let echo = "Send the proposal to the client"
    let result = BriefQualityGate().evaluate(
        .init(
            language: "English",
            overview: echo,
            topics: [.init(id: "topic", text: echo, evidenceSegmentIDs: ["s000001"])],
            decisions: [],
            actionItems: [.init(id: "action", text: echo, owner: nil, dueDate: nil, evidenceSegmentIDs: ["s000001", "s000002", "s000003"])],
            openQuestions: [],
            warnings: []
        ),
        transcript: transcript,
        rawNotes: notes
    )

    #expect(result.overviewSupport == .quillSystemNotice)
    #expect(result.payload.topics.isEmpty)
    #expect(result.payload.actionItems.isEmpty)
    #expect(result.warnings.count == 1)
}

@Test func qualityGateKeepsACompactDirectlySupportedAssignedAction() throws {
    let transcript = try fixtureTranscript([
        ("s000001", "me", "Dana will send the proposal on Friday."),
    ])
    let notes = try fixtureNotes(text: "Check formatting later")
    let result = BriefQualityGate().evaluate(
        .init(
            language: "English",
            overview: "Dana will send the proposal on Friday.",
            topics: [],
            decisions: [],
            actionItems: [.init(id: "action", text: "Send the proposal", owner: "Dana", dueDate: nil, evidenceSegmentIDs: ["s000001", "s000001"])],
            openQuestions: [],
            warnings: []
        ),
        transcript: transcript,
        rawNotes: notes
    )

    #expect(result.overviewSupport == .aiGeneratedRequiresReview)
    #expect(result.payload.actionItems.count == 1)
    let action = try #require(result.payload.actionItems.first)
    #expect(action.evidenceSegmentIDs == ["s000001"])
}

@Test func qualityGateRetainsTranscriptFactThatAlsoAppearsInRawNotes() throws {
    let transcript = try fixtureTranscript([
        ("s000001", "me", "Dana approved the budget."),
    ])
    let notes = try fixtureNotes(text: "Dana approved the budget")
    let result = BriefQualityGate().evaluate(
        .init(
            language: "English",
            overview: "Dana approved the budget during the meeting.",
            topics: [],
            decisions: [.init(id: "decision", text: "Dana approved the budget", evidenceSegmentIDs: ["s000001"])],
            actionItems: [],
            openQuestions: [],
            warnings: []
        ),
        transcript: transcript,
        rawNotes: notes
    )

    #expect(result.payload.decisions.count == 1)
}

@Test func qualityGateCompactsEvidenceAndHandlesHebrewOwnerPrefix() throws {
    let transcript = try fixtureTranscript([
        ("s000001", "me", "נדבר על ההצעה."),
        ("s000002", "them", "דנה תשלח את ההצעה ביום שישי."),
        ("s000003", "me", "הלקוח יקבל עדכון."),
    ])
    let notes = try fixtureNotes(text: "לעיין בתיעוד")
    let result = BriefQualityGate().evaluate(
        .init(
            language: "Hebrew",
            overview: "דנה תשלח את ההצעה ביום שישי לאחר הדיון.",
            topics: [],
            decisions: [],
            actionItems: [.init(
                id: "action",
                text: "דנה תשלח את ההצעה",
                owner: "דנה",
                dueDate: "יום שישי",
                evidenceSegmentIDs: ["s000001", "s000002", "s000003"]
            )],
            openQuestions: [],
            warnings: []
        ),
        transcript: transcript,
        rawNotes: notes
    )

    let action = try #require(result.payload.actionItems.first)
    #expect(action.evidenceSegmentIDs == ["s000001", "s000002"])
    #expect(action.dueDate == "יום שישי")
}

@Test func qualityGateSupportsUnicodeTokensOutsideHebrewAndLatin() throws {
    let transcript = try fixtureTranscript([
        ("s000001", "me", "Бюджет утвержден командой."),
    ])
    let notes = try fixtureNotes(text: "Проверить позже")
    let result = BriefQualityGate().evaluate(
        .init(
            language: "Russian",
            overview: "Бюджет утвержден командой на встрече.",
            topics: [],
            decisions: [.init(id: "decision", text: "Бюджет утвержден", evidenceSegmentIDs: ["s000001"])],
            actionItems: [],
            openQuestions: [],
            warnings: []
        ),
        transcript: transcript,
        rawNotes: notes
    )

    #expect(result.payload.decisions.count == 1)
}

private func fixtureTranscript(_ segments: [(String, String, String)]) throws -> SessionTranscript {
    try SessionTranscript(
        engine: "fixture",
        model: "fixture",
        createdAt: "2026-09-02T00:00:00Z",
        speakerLabels: true,
        timestamps: true,
        segments: segments.enumerated().map { index, segment in
            .init(id: segment.0, speaker: segment.1, startMS: index * 1_000, endMS: index * 1_000 + 900, text: segment.2)
        }
    )
}

private func fixtureNotes(text: String) throws -> RawMeetingNotes {
    try RawMeetingNotes(
        sessionID: "fixture",
        revision: 1,
        template: "general",
        updatedAt: "2026-09-02T00:00:00Z",
        notes: [.init(id: "note", text: text, capturedAtMS: 0, createdAt: "2026-09-02T00:00:00Z", updatedAt: "2026-09-02T00:00:00Z")]
    )
}
