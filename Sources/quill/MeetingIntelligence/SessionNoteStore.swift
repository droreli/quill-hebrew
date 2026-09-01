import Darwin
import Foundation

/// The only writer for a session's user-owned `raw-notes.json` artifact.
///
/// An advisory lock serializes edits across independent store instances and
/// processes. Every successful mutation increments the revision and atomically
/// replaces the complete document, so readers never observe partial JSON.
actor SessionNoteStore {
  enum StoreError: Error, LocalizedError, Equatable {
    case noteNotFound(String)
    case invalidCapturedAtMS(Int)
    case sessionIdentityMismatch(expected: String, found: String)
    case sessionLockUnavailable(String)

    var errorDescription: String? {
      switch self {
      case .noteNotFound(let id): "No raw note with identifier \(id)"
      case .invalidCapturedAtMS(let value):
        "Meeting-relative timestamp must be non-negative, got \(value)"
      case .sessionIdentityMismatch(let expected, let found):
        "raw-notes.json belongs to \(found), not session \(expected)"
      case .sessionLockUnavailable(let message):
        "Could not acquire the local notes lock: \(message)"
      }
    }
  }

  private let notesURL: URL
  private let lockURL: URL
  private let sessionID: String
  private let now: @Sendable () -> Date
  private let writeAtomically: @Sendable (Data, URL) throws -> Void
  private let lockTimeout: Duration
  private let lockRetryInterval: Duration
  private var document: RawMeetingNotes

  /// Opens an existing document or creates an in-memory empty document. The
  /// file is created on the first mutation, keeping an untouched session
  /// directory byte-for-byte unchanged.
  init(
    sessionDirectory: URL,
    sessionID: String? = nil,
    template: String = "general",
    now: @escaping @Sendable () -> Date = Date.init,
    writeAtomically: @escaping @Sendable (Data, URL) throws -> Void = SessionNoteStore
      .defaultAtomicWrite,
    lockTimeout: Duration = .seconds(2),
    lockRetryInterval: Duration = .milliseconds(25)
  ) throws {
    guard lockTimeout > .zero, lockRetryInterval > .zero else {
      throw StoreError.sessionLockUnavailable("lock timeout and retry interval must be positive")
    }
    let suppliedIdentity = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let resolvedIdentity: String
    if let suppliedIdentity {
      resolvedIdentity = suppliedIdentity
    } else {
      resolvedIdentity = try SessionIdentity(sessionDirectory: sessionDirectory).value
    }
    let url = sessionDirectory.appendingPathComponent("raw-notes.json")
    let decoder = JSONDecoder()

    if FileManager.default.fileExists(atPath: url.path) {
      let existing = try decoder.decode(RawMeetingNotes.self, from: Data(contentsOf: url))
      guard existing.sessionID == resolvedIdentity else {
        throw StoreError.sessionIdentityMismatch(
          expected: resolvedIdentity, found: existing.sessionID)
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
    lockURL = sessionDirectory.appendingPathComponent(".raw-notes.lock")
    self.sessionID = resolvedIdentity
    self.now = now
    self.writeAtomically = writeAtomically
    self.lockTimeout = lockTimeout
    self.lockRetryInterval = lockRetryInterval
  }

  /// Returns a consistent, immutable copy at the store's current revision.
  func snapshot() -> RawMeetingNotes {
    document
  }

  /// Template choice is user-owned note state, not a UI-only preference.
  /// Persist it through the same revisioned atomic document as note edits.
  func setTemplate(_ template: String) async throws {
    try await commit { current in
      try RawMeetingNotes(
        sessionID: sessionID,
        revision: current.revision + 1,
        template: template,
        updatedAt: Self.timestamp(now()),
        notes: current.notes
      )
    }
  }

  /// A descriptive alias for callers that model template selection as an
  /// update. Kept alongside `setTemplate` for existing integrations.
  func updateTemplate(_ template: String) async throws {
    try await setTemplate(template)
  }

  @discardableResult
  func add(text: String, capturedAtMS: Int) async throws -> RawMeetingNotes.Note {
    try requireMeetingRelativeTimestamp(capturedAtMS)
    return try await commit { current in
      let timestamp = Self.timestamp(now())
      let note = RawMeetingNotes.Note(
        id: UUID().uuidString.lowercased(),
        text: text,
        capturedAtMS: capturedAtMS,
        createdAt: timestamp,
        updatedAt: timestamp
      )
      return (
        try updatedDocument(from: current, notes: current.notes + [note], updatedAt: timestamp),
        note
      )
    }
  }

  /// Updates text and, when supplied, the meeting-relative timestamp while
  /// retaining the note's original creation time and identifier.
  @discardableResult
  func update(id: String, text: String, capturedAtMS: Int? = nil) async throws
    -> RawMeetingNotes.Note
  {
    if let capturedAtMS {
      try requireMeetingRelativeTimestamp(capturedAtMS)
    }
    return try await commit { current in
      guard let index = current.notes.firstIndex(where: { $0.id == id }) else {
        throw StoreError.noteNotFound(id)
      }

      let timestamp = Self.timestamp(now())
      let previous = current.notes[index]
      let note = RawMeetingNotes.Note(
        id: previous.id,
        text: text,
        capturedAtMS: capturedAtMS ?? previous.capturedAtMS,
        createdAt: previous.createdAt,
        updatedAt: timestamp
      )
      var notes = current.notes
      notes[index] = note
      return (try updatedDocument(from: current, notes: notes, updatedAt: timestamp), note)
    }
  }

  func delete(id: String) async throws {
    try await commit { current in
      guard let index = current.notes.firstIndex(where: { $0.id == id }) else {
        throw StoreError.noteNotFound(id)
      }

      var notes = current.notes
      notes.remove(at: index)
      return try updatedDocument(from: current, notes: notes, updatedAt: Self.timestamp(now()))
    }
  }

  private func requireMeetingRelativeTimestamp(_ value: Int) throws {
    guard value >= 0 else { throw StoreError.invalidCapturedAtMS(value) }
  }

  private func updatedDocument(
    from current: RawMeetingNotes,
    notes: [RawMeetingNotes.Note],
    updatedAt: String
  ) throws -> RawMeetingNotes {
    try RawMeetingNotes(
      sessionID: sessionID,
      revision: current.revision + 1,
      template: current.template,
      updatedAt: updatedAt,
      notes: notes
    )
  }

  /// Reads the canonical document while holding the session lock, commits the
  /// candidate file, and only then advances this actor's in-memory snapshot.
  /// This keeps failed writes invisible to callers and prevents independent
  /// stores from overwriting one another with stale revisions.
  private func commit(_ mutation: (RawMeetingNotes) throws -> RawMeetingNotes) async throws {
    try await withExclusiveSessionLock {
      let candidate = try mutation(loadCurrentDocument())
      try persist(candidate)
      document = candidate
    }
  }

  private func commit<Value>(
    _ mutation: (RawMeetingNotes) throws -> (RawMeetingNotes, Value)
  ) async throws -> Value {
    try await withExclusiveSessionLock {
      let (candidate, value) = try mutation(loadCurrentDocument())
      try persist(candidate)
      document = candidate
      return value
    }
  }

  private func loadCurrentDocument() throws -> RawMeetingNotes {
    guard FileManager.default.fileExists(atPath: notesURL.path) else { return document }
    let current = try JSONDecoder().decode(RawMeetingNotes.self, from: Data(contentsOf: notesURL))
    guard current.sessionID == sessionID else {
      throw StoreError.sessionIdentityMismatch(expected: sessionID, found: current.sessionID)
    }
    return current
  }

  private func persist(_ candidate: RawMeetingNotes) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(candidate)
    // Foundation's atomic option writes a sibling temporary file and swaps
    // it into place, preserving the prior complete file if this write fails.
    try writeAtomically(data, notesURL)
  }

  private func withExclusiveSessionLock<Value>(_ operation: () throws -> Value) async throws
    -> Value
  {
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw StoreError.sessionLockUnavailable(String(cString: strerror(errno)))
    }
    defer { close(descriptor) }

    let clock = ContinuousClock()
    let deadline = clock.now + lockTimeout
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let error = errno
      guard error == EWOULDBLOCK || error == EAGAIN else {
        throw StoreError.sessionLockUnavailable(String(cString: strerror(error)))
      }
      guard clock.now < deadline else {
        throw StoreError.sessionLockUnavailable("timed out after \(lockTimeout)")
      }
      try Task.checkCancellation()
      try await Task.sleep(for: lockRetryInterval)
    }
    defer { flock(descriptor, LOCK_UN) }
    return try operation()
  }

  private static func defaultAtomicWrite(_ data: Data, _ url: URL) throws {
    try data.write(to: url, options: .atomic)
  }

  private static func timestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
