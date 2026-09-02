import Foundation
import Testing

@testable import quill

/// An opt-in end-to-end guard for a user-owned local session. The path is
/// supplied only by the local test environment, so neither transcripts nor
/// notes are copied into the repository or test fixtures.
@Test func localBriefQualityRegressionFixtureWhenExplicitlyEnabled() throws {
    guard let path = ProcessInfo.processInfo.environment["QUILL_LOCAL_BRIEF_REGRESSION_SESSION"],
          !path.isEmpty
    else { return }

    let session = URL(fileURLWithPath: path, isDirectory: true)
    let transcript = try JSONDecoder().decode(
        SessionTranscript.self,
        from: Data(contentsOf: session.appendingPathComponent("transcript.json"))
    )
    let brief = try JSONDecoder().decode(
        MeetingBrief.self,
        from: Data(contentsOf: session.appendingPathComponent("artifacts/meeting-brief.json"))
    )
    try brief.validateEvidence(against: transcript)

    // The fixture is intentionally a low-coverage session whose earlier
    // artifact promoted raw notes into a broad, unassigned action. The safe
    // outcome is a Quill-owned coverage notice with no invented claims.
    #expect(brief.overviewSupport == .quillSystemNotice)
    #expect(brief.topics.isEmpty)
    #expect(brief.decisions.isEmpty)
    #expect(brief.actionItems.isEmpty)
    #expect(brief.openQuestions.isEmpty)
    #expect(brief.warnings.contains(MeetingBrief.requiredReviewWarning))
    #expect(brief.warnings.contains { $0.contains("לא פורסמו טענות אוטומטיות") })
}
