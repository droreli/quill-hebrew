import Foundation
import Testing

@testable import quill

@Test func meetingLibraryKeepsUntranscribedSessionsVisibleAndReportsLocalFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-library-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appendingPathComponent("2026.09.02-1030")
    let waiting = root.appendingPathComponent("2026.09.01-0930")
    try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
    let meta = """
    {"started":"2026-09-02T10:30:00Z","ended":"2026-09-02T10:31:30Z","duration_seconds":90,"files":{"mic":"mic.caf","system":"system.caf","mixed":"mixed.m4a"}}
    """
    try Data(meta.utf8).write(to: ready.appendingPathComponent("meta.json"))
    try Data("{}".utf8).write(to: waiting.appendingPathComponent("meta.json"))
    try Data().write(to: ready.appendingPathComponent("mic.caf"))
    try Data().write(to: ready.appendingPathComponent("system.caf"))
    try Data().write(to: ready.appendingPathComponent("mixed.m4a"))
    let transcript = try SessionTranscript(
        engine: "fixture", model: "fixture", createdAt: "2026-09-02T10:32:00Z",
        speakerLabels: false, timestamps: true,
        segments: [.init(id: "s000001", speaker: "me", startMS: 0, endMS: 1_000, text: "Ready")]
    )
    try JSONEncoder().encode(transcript).write(to: ready.appendingPathComponent("transcript.json"))

    let snapshot = MeetingLibrarySessions.snapshot(in: root)
    #expect(snapshot.errorMessage == nil)
    #expect(snapshot.sessions.map(\.title) == ["2026.09.02-1030", "2026.09.01-0930"])
    #expect(snapshot.sessions[0].transcript == .ready(segmentCount: 1))
    #expect(snapshot.sessions[0].audio == .init(microphoneAvailable: true, systemAvailable: true, listeningCopyAvailable: true))
    #expect(snapshot.sessions[1].transcript == .waiting)
}

@Test func meetingLibraryReportsUnreadableTranscriptWithoutHidingSession() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-library-unreadable-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("2026.09.02-1200")
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: session.appendingPathComponent("meta.json"))
    try Data("not json".utf8).write(to: session.appendingPathComponent("transcript.json"))

    let snapshot = MeetingLibrarySessions.snapshot(in: root)
    #expect(snapshot.sessions.count == 1)
    #expect(snapshot.sessions[0].transcript == .unreadable)
    #expect(snapshot.sessions[0].transcript.canBrief == false)
}
