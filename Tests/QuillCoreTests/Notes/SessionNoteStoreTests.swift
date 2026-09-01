import CryptoKit
import Foundation
import Testing
@testable import quill

@Test func legacySessionIdentityIsStableAndDoesNotRewriteMetadata() throws {
    let fixture = try makeSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let metaHashBefore = try sha256(of: fixture.directory.appendingPathComponent("meta.json"))
    let first = try SessionIdentity(sessionDirectory: fixture.directory)
    let second = try SessionIdentity(sessionDirectory: fixture.directory)

    #expect(first == second)
    #expect(UUID(uuidString: first.value) != nil)
    #expect(try sha256(of: fixture.directory.appendingPathComponent("meta.json")) == metaHashBefore)
}

@Test func storeMutationsAreAtomicAndLeaveSourceArtifactsUntouched() async throws {
    let fixture = try makeSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let sourceHashesBefore = try sourceArtifactHashes(in: fixture.directory)
    let store = try SessionNoteStore(
        sessionDirectory: fixture.directory,
        now: { Date(timeIntervalSince1970: 1_725_174_000) }
    )

    let added = try await store.add(text: "# החלטה\n- Start a two-week pilot", capturedAtMS: 542_000)
    let edited = try await store.update(id: added.id, text: "# החלטה\n- Start a three-week pilot")
    #expect(edited.id == added.id)
    #expect(edited.createdAt == added.createdAt)
    #expect(edited.updatedAt == "2024-09-01T07:00:00Z")

    var snapshot = await store.snapshot()
    #expect(snapshot.revision == 2)
    #expect(snapshot.notes == [edited])

    try await store.delete(id: added.id)
    snapshot = await store.snapshot()
    #expect(snapshot.revision == 3)
    #expect(snapshot.notes.isEmpty)

    let persisted = try JSONDecoder().decode(
        RawMeetingNotes.self,
        from: Data(contentsOf: fixture.directory.appendingPathComponent("raw-notes.json"))
    )
    #expect(persisted == snapshot)
    #expect(try sourceArtifactHashes(in: fixture.directory) == sourceHashesBefore)
}

@Test func serializedConcurrentEditsProduceMonotonicRevisions() async throws {
    let fixture = try makeSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let store = try SessionNoteStore(sessionDirectory: fixture.directory)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0 ..< 32 {
            group.addTask {
                _ = try await store.add(text: "note \(index)", capturedAtMS: index * 100)
            }
        }
        try await group.waitForAll()
    }

    let snapshot = await store.snapshot()
    #expect(snapshot.revision == 32)
    #expect(snapshot.notes.count == 32)
    #expect(Set(snapshot.notes.map(\.id)).count == 32)
    #expect(snapshot.notes.allSatisfy { $0.capturedAtMS >= 0 })
}

@Test func storeRejectsNegativeMeetingRelativeTimestamps() async throws {
    let fixture = try makeSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let store = try SessionNoteStore(sessionDirectory: fixture.directory)
    await #expect(throws: SessionNoteStore.StoreError.invalidCapturedAtMS(-1)) {
        try await store.add(text: "impossible", capturedAtMS: -1)
    }
    #expect((await store.snapshot()).revision == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("raw-notes.json").path))
}

private func makeSessionFixture() throws -> (directory: URL, sourceFiles: [String]) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-notes-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let contents: [String: Data] = [
        "meta.json": Data("{\"started\":\"2024-08-26T12:00:00Z\",\"files\":{\"mic\":\"mic.caf\",\"system\":\"system.caf\"}}".utf8),
        "mic.caf": Data([0, 1, 2, 3]),
        "system.caf": Data([4, 5, 6, 7]),
        "transcript.json": Data("{\"engine\":\"fixture\",\"model\":\"fixture\",\"created_at\":\"2024-08-26T12:00:00Z\",\"speaker_labels\":true,\"timestamps\":true,\"segments\":[]}".utf8),
    ]
    for (name, data) in contents {
        try data.write(to: directory.appendingPathComponent(name))
    }
    return (directory, Array(contents.keys))
}

private func sourceArtifactHashes(in directory: URL) throws -> [String: String] {
    let names = ["meta.json", "mic.caf", "system.caf", "transcript.json"]
    return try Dictionary(uniqueKeysWithValues: names.map { name in
        (name, try sha256(of: directory.appendingPathComponent(name)))
    })
}

private func sha256(of url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
