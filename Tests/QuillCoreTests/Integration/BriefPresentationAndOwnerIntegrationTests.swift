import CryptoKit
import Foundation
import Testing
@testable import quill

@Test func briefPresentationUsesTranscriptAndSortedRawNoteDigests() async throws {
    let session = try makeBriefPresentationSession()
    defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }

    let transcriptData = try Data(contentsOf: session.appendingPathComponent("transcript.json"))
    let originalNotes = try presentationNotes(text: "Original cue", updatedAt: "2026-09-01T00:00:00Z")
    let input = SummaryInput(
        transcriptSHA256: presentationDigest(transcriptData),
        transcriptSegmentCount: 1,
        rawNotesRevision: originalNotes.revision,
        rawNotesSHA256: try presentationNotesDigest(originalNotes)
    )
    let brief = try presentationBrief(input: input)

    let current = await MainActor.run {
        meetingBriefPresentationState(brief: brief, sessionDirectory: session, rawNotes: originalNotes)
    }
    if case .ready = current { } else { Issue.record("Expected matching inputs to be ready") }

    let changedNotes = try presentationNotes(text: "Changed cue", updatedAt: "2026-09-01T00:00:01Z")
    let noteStale = await MainActor.run {
        meetingBriefPresentationState(brief: brief, sessionDirectory: session, rawNotes: changedNotes)
    }
    if case .stale = noteStale { } else { Issue.record("Expected changed raw-note digest to be stale") }

    let changedTranscript = try SessionTranscript(
        engine: "fixture", model: "fixture", createdAt: "2026-09-01T00:00:01Z",
        speakerLabels: true, timestamps: true,
        segments: [.init(id: "s000001", speaker: "me", startMS: 0, endMS: 1_000, text: "Changed transcript")]
    )
    try JSONEncoder().encode(changedTranscript).write(to: session.appendingPathComponent("transcript.json"), options: .atomic)
    let transcriptStale = await MainActor.run {
        meetingBriefPresentationState(brief: brief, sessionDirectory: session, rawNotes: originalNotes)
    }
    if case .stale = transcriptStale { } else { Issue.record("Expected changed transcript digest to be stale") }

    let coordinatorStale = await MainActor.run {
        meetingBriefPresentationState(
            brief: brief,
            sessionDirectory: session,
            rawNotes: originalNotes,
            coordinatorReportedStale: true
        )
    }
    if case .stale = coordinatorStale { } else { Issue.record("Expected coordinator stale status to be preserved") }
}

@Test func coordinatorOwnerRetainsOneStatusRouteAcrossResumeAndGenerate() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-owner-\(UUID().uuidString)", isDirectory: true)
    let session = root.appendingPathComponent("session-a", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("{}".utf8).write(to: session.appendingPathComponent("meta.json"))
    let emptyTranscript = try SessionTranscript(
        engine: "fixture", model: "fixture", createdAt: "2026-09-01T00:00:00Z",
        speakerLabels: true, timestamps: true, segments: []
    )
    try JSONEncoder().encode(emptyTranscript).write(to: session.appendingPathComponent("transcript.json"))
    try MeetingBriefStore(sessionDirectory: session).markPending()

    let firstStatuses = OwnerStatusRecorder()
    let ignoredStatuses = OwnerStatusRecorder()
    let owner = BriefCoordinatorOwner(engine: NoInferenceEngine())
    await owner.installStatusHandler { state in Task { await firstStatuses.append(state) } }
    await owner.installStatusHandler { state in Task { await ignoredStatuses.append(state) } }

    await owner.resumePending(root: root)
    try await waitForOwnerStatus { await firstStatuses.readyCount == 1 }
    try await owner.enqueue(session)
    try await waitForOwnerStatus { await firstStatuses.readyCount == 2 }

    #expect(await ignoredStatuses.count == 0)
}

private struct NoInferenceEngine: SummarizationEngine {
    func summarize(transcript: SessionTranscript, rawNotes: RawMeetingNotes, input: SummaryInput) async throws -> MeetingBrief {
        Issue.record("Empty transcripts must be completed by Quill without inference")
        throw CancellationError()
    }
}

private actor OwnerStatusRecorder {
    private var states: [PostMeetingCoordinator.State] = []

    func append(_ state: PostMeetingCoordinator.State) { states.append(state) }
    var count: Int { states.count }
    var readyCount: Int { states.reduce(into: 0) { if case .ready = $1 { $0 += 1 } } }
}

private func makeBriefPresentationSession() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-brief-presentation-\(UUID().uuidString)", isDirectory: true)
    let session = root.appendingPathComponent("session-a", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let transcript = try SessionTranscript(
        engine: "fixture", model: "fixture", createdAt: "2026-09-01T00:00:00Z",
        speakerLabels: true, timestamps: true,
        segments: [.init(id: "s000001", speaker: "me", startMS: 0, endMS: 1_000, text: "Original transcript")]
    )
    try JSONEncoder().encode(transcript).write(to: session.appendingPathComponent("transcript.json"))
    return session
}

private func presentationNotes(text: String, updatedAt: String) throws -> RawMeetingNotes {
    try RawMeetingNotes(
        sessionID: "session-a", revision: 3, template: "general", updatedAt: updatedAt,
        notes: [.init(id: "note-a", text: text, capturedAtMS: 0, createdAt: "2026-09-01T00:00:00Z", updatedAt: updatedAt)]
    )
}

private func presentationBrief(input: SummaryInput) throws -> MeetingBrief {
    try MeetingBrief(
        id: "brief-a", createdAt: "2026-09-01T00:00:00Z", language: "english", inputs: input,
        generator: try .init(engine: "fixture", runtimeVersion: "test", modelID: "fixture", modelRevision: nil, quantization: "none", localOnly: true, provenance: "fixture"),
        overview: "Original transcript", topics: [], decisions: [], actionItems: [], openQuestions: [], warnings: []
    )
}

private func presentationNotesDigest(_ notes: RawMeetingNotes) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return presentationDigest(try encoder.encode(notes))
}

private func presentationDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func waitForOwnerStatus(
    timeout: Duration = .seconds(3),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !(await condition()) {
        guard clock.now < deadline else {
            throw NSError(domain: "QuillOwnerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for coordinator status"])
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
