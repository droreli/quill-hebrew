import Foundation
import Testing

@testable import quill

@Test func completedTranscriptSessionsListsOnlyReadySessionsNewestFirst() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-completed-sessions-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    func make(_ name: String, transcript: Bool) throws {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("meta.json"))
        if transcript {
            try Data("{}".utf8).write(to: directory.appendingPathComponent("transcript.json"))
        }
    }

    try make("2026.09.01-0900", transcript: true)
    try make("2026.09.02-1100", transcript: true)
    try make("2026.09.02-1200", transcript: false)

    #expect(CompletedTranscriptSessions.directories(in: root).map(\.lastPathComponent) == [
        "2026.09.02-1100", "2026.09.01-0900"
    ])
}
