import CryptoKit
import Foundation
import Testing
@testable import quill

@Test func explicitBriefMarkerLeavesRecordingAndTranscriptSourcesUntouched() throws {
    let session = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-integration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: session) }

    let sources: [String: Data] = [
        "mic.caf": Data([0, 1, 2]),
        "system.caf": Data([3, 4, 5]),
        "mixed.m4a": Data([6, 7, 8]),
        "meta.json": Data("{\"schema_version\":\"quill.session.v1\",\"session_id\":\"session-a\"}".utf8),
        "transcript.json": Data("{\"schema_version\":\"quill.transcript.v1\",\"engine\":\"fixture\",\"model\":\"fixture\",\"created_at\":\"2026-09-01T00:00:00Z\",\"speaker_labels\":true,\"timestamps\":true,\"segments\":[{\"id\":\"s000001\",\"speaker\":\"me\",\"start_ms\":0,\"end_ms\":1,\"text\":\"hello\"}]}".utf8),
    ]
    for (name, data) in sources {
        try data.write(to: session.appendingPathComponent(name), options: .atomic)
    }
    let before = try Dictionary(uniqueKeysWithValues: sources.keys.map { name in
        (name, digest(try Data(contentsOf: session.appendingPathComponent(name))))
    })

    let store = MeetingBriefStore(sessionDirectory: session)
    try store.markPending()

    #expect(store.hasPendingJob())
    let after = try Dictionary(uniqueKeysWithValues: sources.keys.map { name in
        (name, digest(try Data(contentsOf: session.appendingPathComponent(name))))
    })
    #expect(after == before)
}

@Test func providerIsDisabledUntilExplicitlyEnabled() throws {
    let provider = LMStudioProviderConfiguration()
    #expect(!provider.isEnabled)
    #expect(provider.endpoint == "http://127.0.0.1:1234")
    #expect(provider.selectedModelID == "google/gemma-4-26b-a4b-qat")
    #expect(try Config.lmStudioConfiguration(provider: provider).isEnabled == false)
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
