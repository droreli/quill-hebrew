import CryptoKit
import Foundation
import Testing

@testable import quill

@Test func atomicCurrentSwapKeepsReadersResolvableAndPrunesOldGenerations() async throws {
  let session = try makeBriefStoreSession()
  defer { try? FileManager.default.removeItem(at: session) }

  let transcript = try briefStoreTranscript()
  let input = SummaryInput(
    transcriptSHA256: "fixture", transcriptSegmentCount: 1, rawNotesRevision: 0)
  let store = MeetingBriefStore(sessionDirectory: session)
  try store.write(
    briefStoreBrief(input: input, transcript: transcript, id: "seed"), frozenTranscript: transcript,
    expectedInput: input)

  let reader = Task { () -> Bool in
    let current = session.appendingPathComponent("artifacts/.meeting-brief-current")
    for _ in 0..<2_000 {
      guard (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil,
        FileManager.default.fileExists(atPath: current.path),
        (try? Data(contentsOf: store.briefURL)) != nil
      else {
        return false
      }
      await Task.yield()
    }
    return true
  }

  for index in 0..<24 {
    try store.write(
      briefStoreBrief(input: input, transcript: transcript, id: "brief-\(index)"),
      frozenTranscript: transcript,
      expectedInput: input
    )
  }

  #expect(await reader.value)
  let generations = try FileManager.default.contentsOfDirectory(
    at: session.appendingPathComponent("artifacts/.meeting-brief-generations"),
    includingPropertiesForKeys: [.isDirectoryKey],
    options: [.skipsHiddenFiles]
  ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
  #expect(generations.count == 1)
  #expect(
    try JSONDecoder().decode(MeetingBrief.self, from: Data(contentsOf: store.briefURL)).id
      == "brief-23")
}

@Test func concurrentBriefWritersDoNotPruneThePublishedGeneration() async throws {
  let session = try makeBriefStoreSession()
  defer { try? FileManager.default.removeItem(at: session) }

  let transcript = try briefStoreTranscript()
  let input = SummaryInput(
    transcriptSHA256: "fixture", transcriptSegmentCount: 1, rawNotesRevision: 0)

  try await withThrowingTaskGroup(of: Void.self) { group in
    for index in 0..<16 {
      group.addTask {
        let store = MeetingBriefStore(sessionDirectory: session)
        try store.write(
          briefStoreBrief(input: input, transcript: transcript, id: "writer-\(index)"),
          frozenTranscript: transcript,
          expectedInput: input
        )
      }
    }
    try await group.waitForAll()
  }

  let store = MeetingBriefStore(sessionDirectory: session)
  let currentBrief = try JSONDecoder().decode(
    MeetingBrief.self, from: Data(contentsOf: store.briefURL))
  #expect(currentBrief.id.hasPrefix("writer-"))
  #expect(FileManager.default.fileExists(atPath: store.markdownURL.path))

  let generations = try FileManager.default.contentsOfDirectory(
    at: session.appendingPathComponent("artifacts/.meeting-brief-generations"),
    includingPropertiesForKeys: [.isDirectoryKey],
    options: [.skipsHiddenFiles]
  ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
  #expect(generations.count == 1)
}

private func makeBriefStoreSession() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("quill-brief-store-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func briefStoreTranscript() throws -> SessionTranscript {
  try SessionTranscript(
    engine: "fixture", model: "fixture", createdAt: "2026-09-01T00:00:00Z",
    speakerLabels: true, timestamps: true,
    segments: [
      .init(id: "s000001", speaker: "me", startMS: 0, endMS: 1_000, text: "Ship the proposal")
    ]
  )
}

private func briefStoreBrief(input: SummaryInput, transcript: SessionTranscript, id: String) throws
  -> MeetingBrief
{
  let segment = transcript.segments[0]
  let evidence = try EvidenceReference(
    segmentID: segment.id, transcriptJSONPointer: "/segments/0",
    startMS: segment.startMS, endMS: segment.endMS, speaker: segment.speaker
  )
  return try MeetingBrief(
    id: id, createdAt: "2026-09-01T00:00:00Z", language: "english", inputs: input,
    generator: .init(
      engine: "fixture", runtimeVersion: "fixture", modelID: "fixture", modelRevision: nil,
      quantization: "none", localOnly: true, provenance: "fixture"),
    overview: "Proposal", topics: [],
    decisions: [.init(id: "decision", text: "Ship proposal", evidence: [evidence])],
    actionItems: [], openQuestions: [], warnings: []
  )
}
