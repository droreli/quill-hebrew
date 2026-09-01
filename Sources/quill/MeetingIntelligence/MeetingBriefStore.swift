import Darwin
import Foundation

/// The only writer of generated meeting-brief artifacts.  It never opens or
/// writes source audio, metadata, transcript, or raw-note files.
struct MeetingBriefStore: Sendable {
  enum StoreError: Error, LocalizedError {
    case invalidInputs
    case incompleteLegacyPair

    var errorDescription: String? {
      switch self {
      case .invalidInputs: "Generated brief inputs do not match the frozen job inputs"
      case .incompleteLegacyPair:
        "Existing meeting-brief JSON and Markdown artifacts are not a complete pair"
      }
    }
  }

  let sessionDirectory: URL

  var artifactsDirectory: URL {
    sessionDirectory.appendingPathComponent("artifacts", isDirectory: true)
  }

  var briefURL: URL { artifactsDirectory.appendingPathComponent("meeting-brief.json") }
  var markdownURL: URL { artifactsDirectory.appendingPathComponent("meeting-brief.md") }

  /// A durable marker makes an explicitly requested job discoverable after a
  /// quit or crash. It is removed only after a successful write or explicit
  /// cancellation; failed jobs remain available for retry/recovery.
  private var pendingURL: URL { artifactsDirectory.appendingPathComponent("brief-job.json") }
  private var publishLockURL: URL {
    artifactsDirectory.appendingPathComponent(".meeting-brief-publish.lock")
  }

  func markPending() throws {
    try FileManager.default.createDirectory(
      at: artifactsDirectory, withIntermediateDirectories: true)
    let record = PendingJob(schemaVersion: "quill.meeting-brief-job.v1")
    let data = try JSONEncoder.prettySorted.encode(record)
    try data.write(to: pendingURL, options: .atomic)
  }

  func hasPendingJob() -> Bool {
    FileManager.default.fileExists(atPath: pendingURL.path)
  }

  func clearPending() throws {
    guard FileManager.default.fileExists(atPath: pendingURL.path) else { return }
    try FileManager.default.removeItem(at: pendingURL)
  }

  /// Stage each generation as an immutable JSON/Markdown pair, then atomically
  /// switch one `current` link. The stable canonical paths are symlinks into
  /// that link, so a failure cannot expose JSON from one generation with
  /// Markdown from another.
  func write(
    _ brief: MeetingBrief, frozenTranscript: SessionTranscript, expectedInput: SummaryInput
  ) throws {
    guard brief.inputs == expectedInput else { throw StoreError.invalidInputs }
    try brief.validateEvidence(against: frozenTranscript)
    try FileManager.default.createDirectory(
      at: artifactsDirectory, withIntermediateDirectories: true)

    let generation = UUID().uuidString.lowercased()
    let staging = generationsDirectory.appendingPathComponent(
      ".staging-\(generation)", isDirectory: true)
    let final = generationsDirectory.appendingPathComponent(generation, isDirectory: true)
    try FileManager.default.createDirectory(
      at: generationsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    do {
      try JSONEncoder.prettySorted.encode(brief).write(
        to: staging.appendingPathComponent("meeting-brief.json"), options: .atomic)
      try Data(BriefMarkdownRenderer.render(brief).utf8).write(
        to: staging.appendingPathComponent("meeting-brief.md"), options: .atomic)
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw error
    }
    do {
      try withPublishLock {
        // Moving the staged pair into the visible generation set belongs to
        // the same critical section as pruning. Otherwise another process can
        // delete this generation before it becomes current.
        try FileManager.default.moveItem(at: staging, to: final)
        var published = false
        do {
          try migrateLegacyPairIfNeeded()
          try ensureCanonicalLinks()
          try replaceCurrentGeneration(with: generation)
          published = true
        } catch {
          if !published {
            try? FileManager.default.removeItem(at: final)
          }
          throw error
        }

        // Publication is already durable at this point. Cleanup must not turn
        // a readable brief into a reported generation failure.
        try? clearPending()
        try? pruneGenerations(except: generation)
      }
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw error
    }
  }

  private var generationsDirectory: URL {
    artifactsDirectory.appendingPathComponent(".meeting-brief-generations", isDirectory: true)
  }

  private var currentURL: URL {
    artifactsDirectory.appendingPathComponent(".meeting-brief-current")
  }

  private func migrateLegacyPairIfNeeded() throws {
    let fileManager = FileManager.default
    let jsonIsLink = (try? fileManager.destinationOfSymbolicLink(atPath: briefURL.path)) != nil
    let markdownIsLink =
      (try? fileManager.destinationOfSymbolicLink(atPath: markdownURL.path)) != nil
    guard !jsonIsLink || !markdownIsLink else { return }

    let hasJSON = fileManager.fileExists(atPath: briefURL.path)
    let hasMarkdown = fileManager.fileExists(atPath: markdownURL.path)
    guard hasJSON == hasMarkdown else { throw StoreError.incompleteLegacyPair }
    guard hasJSON else { return }

    let generation = "legacy-\(UUID().uuidString.lowercased())"
    let legacy = generationsDirectory.appendingPathComponent(generation, isDirectory: true)
    try fileManager.createDirectory(at: legacy, withIntermediateDirectories: false)
    try Data(contentsOf: briefURL).write(
      to: legacy.appendingPathComponent("meeting-brief.json"), options: .atomic)
    try Data(contentsOf: markdownURL).write(
      to: legacy.appendingPathComponent("meeting-brief.md"), options: .atomic)
    try replaceCurrentGeneration(with: generation)
  }

  private func ensureCanonicalLinks() throws {
    try replaceWithCurrentLink(
      url: briefURL, destination: ".meeting-brief-current/meeting-brief.json")
    try replaceWithCurrentLink(
      url: markdownURL, destination: ".meeting-brief-current/meeting-brief.md")
  }

  private func replaceWithCurrentLink(url: URL, destination: String) throws {
    let fileManager = FileManager.default
    let temporary = artifactsDirectory.appendingPathComponent(
      ".link-\(UUID().uuidString.lowercased())")
    try fileManager.createSymbolicLink(atPath: temporary.path, withDestinationPath: destination)
    try atomicallyReplace(temporary, with: url)
  }

  private func replaceCurrentGeneration(with generation: String) throws {
    let fileManager = FileManager.default
    let temporary = artifactsDirectory.appendingPathComponent(
      ".current-\(UUID().uuidString.lowercased())")
    try fileManager.createSymbolicLink(
      atPath: temporary.path, withDestinationPath: ".meeting-brief-generations/\(generation)")
    try atomicallyReplace(temporary, with: currentURL)
  }

  /// POSIX `rename` replaces an existing directory entry atomically. In
  /// particular, it does not leave the canonical path absent between an
  /// unlink and a move as FileManager's replacement sequence can.
  private func atomicallyReplace(_ temporary: URL, with destination: URL) throws {
    guard rename(temporary.path, destination.path) == 0 else {
      let error = errno
      try? FileManager.default.removeItem(at: temporary)
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
    }
  }

  /// Serializes the publish-and-prune critical section across the GUI app and
  /// the CLI. Without this lock, one process could prune the generation that a
  /// second process had just made current.
  private func withPublishLock<T>(_ body: () throws -> T) throws -> T {
    let descriptor = open(publishLockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
    guard descriptor >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { close(descriptor) }

    guard flock(descriptor, LOCK_EX) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }

  /// Generations are immutable and useful only until a newer pair is safely
  /// published. A failed write exits before this point, retaining the last
  /// published (including migrated legacy) pair for recovery.
  private func pruneGenerations(except currentGeneration: String) throws {
    let fileManager = FileManager.default
    for url in try fileManager.contentsOfDirectory(
      at: generationsDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) where url.lastPathComponent != currentGeneration {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true else { continue }
      try fileManager.removeItem(at: url)
    }
  }

  private struct PendingJob: Codable {
    let schemaVersion: String

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
    }
  }
}

extension JSONEncoder {
  fileprivate static var prettySorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
