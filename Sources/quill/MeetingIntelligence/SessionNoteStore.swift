import Foundation

/// The only writer for a session's user-owned `raw-notes.json` artifact.
///
/// Actor isolation serializes edits in-process. Every successful mutation
/// increments the revision and atomically replaces the complete document, so
/// readers never observe a partially encoded JSON file.
actor SessionNoteStore {
    enum StoreError: Error, LocalizedError, Equatable {
        case noteNotFound(String)
        case invalidCapturedAtMS(Int)
        case sessionIdentityMismatch(expected: String, found: String)

        var errorDescription: String? {
            switch self {
            case let .noteNotFound(id): "No raw note with identifier \(id)"
            case let .invalidCapturedAtMS(value): "Meeting-relative timestamp must be non-negative, got \(value)"
            case let .sessionIdentityMismatch(expected, found):
                "raw-notes.json belongs to \(found), not session \(expected)"
            }
        }
    }

    private let notesURL: URL
    private let sessionID: String
    private let now: @Sendable () -> Date
    private var document: RawMeetingNotes

    /// Opens an existing document or creates an in-memory empty document. The
    /// file is created on the first mutation, keeping an untouched session
    /// directory byte-for-byte unchanged.
    init(
        sessionDirectory: URL,
        template: String = "general",
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let resolvedIdentity = try SessionIdentity(sessionDirectory: sessionDirectory).value
        let url = sessionDirectory.appendingPathComponent("raw-notes.json")
        let decoder = JSONDecoder()

        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try decoder.decode(RawMeetingNotes.self, from: Data(contentsOf: url))
            guard existing.sessionID == resolvedIdentity else {
                throw StoreError.sessionIdentityMismatch(expected: resolvedIdentity, found: existing.sessionID)
            }
            document = existing
        } else {
            let timestamp = Self.timestamp(now())
            document = try RawMeetingNotes(
                sessionID: resolvedIdentity,
                revision: 0,
                template: template,
                updatedAt: timestamp,
                notes: []
            )
        }

        notesURL = url
        sessionID = resolvedIdentity
        self.now = now
    }

    /// Returns a consistent, immutable copy at the store's current revision.
    func snapshot() -> RawMeetingNotes {
        document
    }

    @discardableResult
    func add(text: String, capturedAtMS: Int) throws -> RawMeetingNotes.Note {
        try requireMeetingRelativeTimestamp(capturedAtMS)
        let timestamp = Self.timestamp(now())
        let note = RawMeetingNotes.Note(
            id: UUID().uuidString.lowercased(),
            text: text,
            capturedAtMS: capturedAtMS,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        document = try updatedDocument(notes: document.notes + [note], updatedAt: timestamp)
        try persist()
        return note
    }

    /// Updates text and, when supplied, the meeting-relative timestamp while
    /// retaining the note's original creation time and identifier.
    @discardableResult
    func update(id: String, text: String, capturedAtMS: Int? = nil) throws -> RawMeetingNotes.Note {
        if let capturedAtMS {
            try requireMeetingRelativeTimestamp(capturedAtMS)
        }
        guard let index = document.notes.firstIndex(where: { $0.id == id }) else {
            throw StoreError.noteNotFound(id)
        }

        let timestamp = Self.timestamp(now())
        let previous = document.notes[index]
        let note = RawMeetingNotes.Note(
            id: previous.id,
            text: text,
            capturedAtMS: capturedAtMS ?? previous.capturedAtMS,
            createdAt: previous.createdAt,
            updatedAt: timestamp
        )
        var notes = document.notes
        notes[index] = note
        document = try updatedDocument(notes: notes, updatedAt: timestamp)
        try persist()
        return note
    }

    func delete(id: String) throws {
        guard let index = document.notes.firstIndex(where: { $0.id == id }) else {
            throw StoreError.noteNotFound(id)
        }

        var notes = document.notes
        notes.remove(at: index)
        let timestamp = Self.timestamp(now())
        document = try updatedDocument(notes: notes, updatedAt: timestamp)
        try persist()
    }

    private func requireMeetingRelativeTimestamp(_ value: Int) throws {
        guard value >= 0 else { throw StoreError.invalidCapturedAtMS(value) }
    }

    private func updatedDocument(notes: [RawMeetingNotes.Note], updatedAt: String) throws -> RawMeetingNotes {
        try RawMeetingNotes(
            sessionID: sessionID,
            revision: document.revision + 1,
            template: document.template,
            updatedAt: updatedAt,
            notes: notes
        )
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        // Foundation's atomic option writes a sibling temporary file and swaps
        // it into place, preserving the prior complete file if this write fails.
        try data.write(to: notesURL, options: .atomic)
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
