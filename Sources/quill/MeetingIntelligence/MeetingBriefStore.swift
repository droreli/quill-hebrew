import Foundation

/// The only writer of generated meeting-brief artifacts.  It never opens or
/// writes source audio, metadata, transcript, or raw-note files.
struct MeetingBriefStore: Sendable {
    enum StoreError: Error, LocalizedError {
        case invalidInputs

        var errorDescription: String? {
            switch self {
            case .invalidInputs: "Generated brief inputs do not match the frozen job inputs"
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

    func markPending() throws {
        try FileManager.default.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)
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

    /// Write the reading view first and commit the canonical JSON last. Both
    /// replacements are atomic, so an interruption cannot leave a partial
    /// JSON artifact; the previous canonical brief stays readable until the
    /// final replacement succeeds.
    func write(_ brief: MeetingBrief, frozenTranscript: SessionTranscript, expectedInput: SummaryInput) throws {
        guard brief.inputs == expectedInput else { throw StoreError.invalidInputs }
        try brief.validateEvidence(against: frozenTranscript)
        try FileManager.default.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)

        let json = try JSONEncoder.prettySorted.encode(brief)
        let markdown = Data(BriefMarkdownRenderer.render(brief).utf8)
        try markdown.write(to: markdownURL, options: .atomic)
        try json.write(to: briefURL, options: .atomic)
        try clearPending()
    }

    private struct PendingJob: Codable {
        let schemaVersion: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
        }
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
