import CryptoKit
import Foundation
import Testing
@testable import quill

@Test func interruptedGenerationLeavesLastValidBriefIntact() async throws {
    let session = try makeSession(name: "interrupted")
    let frozen = try frozenInputs(in: session)
    let existing = try makeBrief(input: frozen.input, transcript: frozen.transcript, id: "existing")
    let store = MeetingBriefStore(sessionDirectory: session)
    try store.write(existing, frozenTranscript: frozen.transcript, expectedInput: frozen.input)
    let jsonBefore = try Data(contentsOf: store.briefURL)
    let markdownBefore = try Data(contentsOf: store.markdownURL)

    let engine = ControlledEngine()
    let coordinator = PostMeetingCoordinator(engine: engine)
    try await coordinator.enqueue(session)
    try await waitUntil { await engine.hasStarted }
    #expect(await coordinator.cancel(session))
    await engine.resume()
    try await waitUntil { await coordinator.currentState() == .idle }

    #expect(try Data(contentsOf: store.briefURL) == jsonBefore)
    #expect(try Data(contentsOf: store.markdownURL) == markdownBefore)
    #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent("transcribe.log").path))
    #expect(FileManager.default.fileExists(atPath: session.appendingPathComponent("brief.log").path))
}

@Test func noteEditDuringGenerationProducesStaleBrief() async throws {
    let session = try makeSession(name: "stale")
    let engine = ControlledEngine()
    let recorder = StateRecorder()
    let coordinator = PostMeetingCoordinator(engine: engine)
    await coordinator.setStatusHandler { state in
        Task { await recorder.append(state) }
    }
    try await coordinator.enqueue(session)
    try await waitUntil { await engine.hasStarted }

    try writeNotes(in: session, revision: 1)
    await engine.resume()
    try await waitUntil { await recorder.hasReady(stale: true) }

    let brief = try JSONDecoder().decode(
        MeetingBrief.self,
        from: Data(contentsOf: session.appendingPathComponent("artifacts/meeting-brief.json"))
    )
    #expect(brief.inputs.rawNotesRevision == 0)
    #expect(try String(contentsOf: session.appendingPathComponent("brief.log"), encoding: .utf8).contains("stale inputs"))
}

@Test func rawNoteContentChangeWithSameRevisionProducesStaleBrief() async throws {
    let session = try makeSession(name: "content-stale")
    let engine = ControlledEngine()
    let recorder = StateRecorder()
    let coordinator = PostMeetingCoordinator(engine: engine)
    await coordinator.setStatusHandler { state in Task { await recorder.append(state) } }
    try await coordinator.enqueue(session)
    try await waitUntil { await engine.hasStarted }

    try writeNotes(in: session, revision: 0, noteText: "Changed without a revision bump")
    await engine.resume()
    try await waitUntil { await recorder.hasReady(stale: true) }
}

@Test func rawNotesForAnotherSessionAreRejectedBeforeGeneration() async throws {
    let session = try makeSession(name: "wrong-notes-session")
    try writeNotes(in: session, revision: 0, sessionID: "another-session")
    let coordinator = PostMeetingCoordinator(engine: ScriptedEngine(outcomes: [.success]))

    await #expect(throws: PostMeetingCoordinator.CoordinatorError.self) {
        try await coordinator.enqueue(session)
    }
}

@Test func emptyTranscriptPublishesQuillCoverageWarningWithoutStartingEngine() async throws {
    let session = try makeSession(name: "empty-transcript")
    let empty = try SessionTranscript(
        engine: "fixture", model: "fixture", createdAt: "2026-09-01T00:00:00Z",
        speakerLabels: true, timestamps: true, segments: []
    )
    try JSONEncoder().encode(empty).write(to: session.appendingPathComponent("transcript.json"))
    let engine = ControlledEngine()
    let coordinator = PostMeetingCoordinator(engine: engine)
    try await coordinator.enqueue(session)
    let briefURL = session.appendingPathComponent("artifacts/meeting-brief.json")
    try await waitUntil {
        let exists = FileManager.default.fileExists(atPath: briefURL.path)
        let state = await coordinator.currentState()
        return exists && state == .idle
    }

    #expect(!(await engine.hasStarted))
    let brief = try JSONDecoder().decode(MeetingBrief.self, from: Data(contentsOf: briefURL))
    #expect(brief.overviewSupport == .quillSystemNotice)
    #expect(brief.warnings.contains { $0.contains("zero segments") })
}

@Test func cancellingQueuedJobLeavesActiveJobStateUntouched() async throws {
    let first = try makeSession(name: "active")
    let second = try makeSession(name: "queued")
    let engine = ControlledEngine()
    let coordinator = PostMeetingCoordinator(engine: engine)
    try await coordinator.enqueue(first)
    try await waitUntil { await engine.hasStarted }
    try await coordinator.enqueue(second)
    let activeState = await coordinator.currentState()

    #expect(await coordinator.cancel(second))
    #expect(await coordinator.currentState() == activeState)
    await engine.resume()
    try await waitUntil { await coordinator.currentState() == .idle }
}

@Test func failedJobDoesNotBlockLaterJobs() async throws {
    let first = try makeSession(name: "first")
    let second = try makeSession(name: "second")
    let coordinator = PostMeetingCoordinator(engine: ScriptedEngine(outcomes: [.failure, .success]))

    try await coordinator.enqueue(first)
    try await coordinator.enqueue(second)
    let secondBrief = second.appendingPathComponent("artifacts/meeting-brief.json")
    try await waitUntil { FileManager.default.fileExists(atPath: secondBrief.path) }

    #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("artifacts/brief-job.json").path))
    #expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent("artifacts/brief-job.json").path))
    #expect(try String(contentsOf: first.appendingPathComponent("brief.log"), encoding: .utf8).contains("generation failed"))
}

private actor ControlledEngine: SummarizationEngine {
    private var didStart = false
    private var continuation: CheckedContinuation<Void, Never>?

    var hasStarted: Bool { didStart }

    func summarize(transcript: SessionTranscript, rawNotes: RawMeetingNotes, input: SummaryInput) async throws -> MeetingBrief {
        didStart = true
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
        return try makeBrief(input: input, transcript: transcript, id: UUID().uuidString)
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ScriptedEngine: SummarizationEngine {
    enum Outcome { case failure, success }
    private var outcomes: [Outcome]

    init(outcomes: [Outcome]) { self.outcomes = outcomes }

    func summarize(transcript: SessionTranscript, rawNotes: RawMeetingNotes, input: SummaryInput) async throws -> MeetingBrief {
        switch outcomes.removeFirst() {
        case .failure: throw FixtureError.expectedFailure
        case .success: return try makeBrief(input: input, transcript: transcript, id: UUID().uuidString)
        }
    }
}

private actor StateRecorder {
    private var states: [PostMeetingCoordinator.State] = []

    func append(_ state: PostMeetingCoordinator.State) { states.append(state) }
    func hasReady(stale: Bool) -> Bool {
        states.contains {
            if case let .ready(_, recordedStale) = $0 { return recordedStale == stale }
            return false
        }
    }
}

private enum FixtureError: Error { case expectedFailure, timeout }

private func makeSession(name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-wp5-\(UUID().uuidString)")
    let session = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: session.appendingPathComponent("meta.json"))
    let transcript = try SessionTranscript(
        engine: "fixture",
        model: "fixture",
        createdAt: "2026-09-01T00:00:00Z",
        speakerLabels: true,
        timestamps: true,
        segments: [.init(id: "s000001", speaker: "me", startMS: 0, endMS: 1_000, text: "Send proposal")]
    )
    try JSONEncoder().encode(transcript).write(to: session.appendingPathComponent("transcript.json"))
    try writeNotes(in: session, revision: 0)
    return session
}

private func writeNotes(in session: URL, revision: Int, noteText: String? = nil, sessionID: String? = nil) throws {
    let noteItems = noteText.map {
        [RawMeetingNotes.Note(id: "note-1", text: $0, capturedAtMS: 0, createdAt: "2026-09-01T00:00:00Z", updatedAt: "2026-09-01T00:00:00Z")]
    } ?? []
    let notes = try RawMeetingNotes(
        sessionID: try (sessionID ?? SessionIdentity(sessionDirectory: session).value),
        revision: revision,
        template: "general",
        updatedAt: "2026-09-01T00:00:00Z",
        notes: noteItems
    )
    try JSONEncoder().encode(notes).write(to: session.appendingPathComponent("raw-notes.json"), options: .atomic)
}

private func frozenInputs(in session: URL) throws -> (transcript: SessionTranscript, input: SummaryInput) {
    let transcriptData = try Data(contentsOf: session.appendingPathComponent("transcript.json"))
    let transcript = try JSONDecoder().decode(SessionTranscript.self, from: transcriptData)
    let notes = try JSONDecoder().decode(RawMeetingNotes.self, from: Data(contentsOf: session.appendingPathComponent("raw-notes.json")))
    return (transcript, .init(transcriptSHA256: sha256(transcriptData), transcriptSegmentCount: transcript.segments.count, rawNotesRevision: notes.revision))
}

private func makeBrief(input: SummaryInput, transcript: SessionTranscript, id: String) throws -> MeetingBrief {
    let segment = transcript.segments[0]
    let evidence = try EvidenceReference(
        segmentID: segment.id,
        transcriptJSONPointer: "/segments/0",
        startMS: segment.startMS,
        endMS: segment.endMS,
        speaker: segment.speaker
    )
    return try MeetingBrief(
        id: id,
        createdAt: "2026-09-01T00:00:00Z",
        language: "english",
        inputs: input,
        generator: try .init(engine: "fake", runtimeVersion: "test", modelID: "fake", modelRevision: nil, quantization: "none", localOnly: true, provenance: "fixture"),
        overview: "Proposal",
        topics: [],
        decisions: [.init(id: "decision", text: "Send proposal", evidence: [evidence])],
        actionItems: [],
        openQuestions: [],
        warnings: []
    )
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func waitUntil(
    timeout: Duration = .seconds(3),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !(await condition()) {
        guard clock.now < deadline else { throw FixtureError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}
