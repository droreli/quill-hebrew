import CryptoKit
import Foundation

/// Serial, explicitly-triggered post-transcript brief pipeline. It is kept
/// separate from `TranscriptionCoordinator`: no recording or transcription
/// lifecycle is changed by generating, failing, or cancelling a brief.
actor PostMeetingCoordinator {
    enum State: Sendable, Equatable {
        case idle
        case preparing(session: String, queued: Int)
        case generating(session: String, queued: Int)
        case ready(session: String, stale: Bool)
        case failed(session: String, message: String)
        case cancelled(session: String)
    }

    enum CoordinatorError: Error, LocalizedError {
        case duplicateJob(URL)
        case missingRawNotes(URL)
        case rawNotesSessionMismatch(expected: String, found: String)
        case staleTranscript(URL)

        var errorDescription: String? {
            switch self {
            case let .duplicateJob(url): "A brief job is already active for \(url.lastPathComponent)"
            case let .missingRawNotes(url): "No raw-notes.json at \(url.path)"
            case let .rawNotesSessionMismatch(expected, found): "raw-notes.json belongs to \(found), not session \(expected)"
            case let .staleTranscript(url): "Transcript changed while preparing \(url.path)"
            }
        }
    }

    private struct Job: Sendable {
        let id: UUID
        let sessionDirectory: URL
        let transcript: SessionTranscript
        let rawNotes: RawMeetingNotes
        let input: SummaryInput
    }

    private let engine: any SummarizationEngine
    private var queue: [Job] = []
    private var currentJob: Job?
    private var drainTask: Task<Void, Never>?
    private var generationTask: Task<MeetingBrief, Error>?
    private var cancelledJobIDs = Set<UUID>()
    private var state: State = .idle
    private var statusHandler: (@Sendable (State) -> Void)?

    init(engine: any SummarizationEngine) {
        self.engine = engine
    }

    func setStatusHandler(_ handler: @escaping @Sendable (State) -> Void) {
        statusHandler = handler
    }

    func currentState() -> State { state }

    /// Captures immutable values at explicit request time. Any later source
    /// edit is detectable without ever modifying those source files.
    func enqueue(_ sessionDirectory: URL) throws {
        guard !containsActiveJob(for: sessionDirectory) else {
            throw CoordinatorError.duplicateJob(sessionDirectory)
        }
        let job = try snapshot(for: sessionDirectory)
        try MeetingBriefStore(sessionDirectory: sessionDirectory).markPending()
        queue.append(job)
        drainIfNeeded()
    }

    /// Retry is an explicit fresh request, so it freezes the transcript and
    /// note revision currently on disk rather than reusing a failed snapshot.
    func retry(_ sessionDirectory: URL) throws {
        try enqueue(sessionDirectory)
    }

    /// Cancels an active generation or removes queued work. Cancellation is
    /// cooperative for engines, but no artifact is written after cancellation.
    @discardableResult
    func cancel(_ sessionDirectory: URL) -> Bool {
        if currentJob?.sessionDirectory.standardizedFileURL == sessionDirectory.standardizedFileURL {
            if let currentJob { cancelledJobIDs.insert(currentJob.id) }
            generationTask?.cancel()
            return true
        }
        guard let index = queue.firstIndex(where: {
            $0.sessionDirectory.standardizedFileURL == sessionDirectory.standardizedFileURL
        }) else { return false }
        queue.remove(at: index)
        let store = MeetingBriefStore(sessionDirectory: sessionDirectory)
        try? store.clearPending()
        // A queued cancellation must not replace the visible state of an
        // unrelated active generation.
        if currentJob == nil {
            publish(.cancelled(session: sessionDirectory.lastPathComponent))
        }
        log(sessionDirectory, "queued generation cancelled")
        return true
    }

    /// Resumes only previously explicit jobs, identified by their durable
    /// marker. It does not scan all transcripts and therefore never turns
    /// startup into automatic generation.
    func resumePending(root: URL) {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard MeetingBriefStore(sessionDirectory: directory).hasPendingJob() else { continue }
            do {
                try enqueue(directory)
            } catch {
                log(directory, "recovery skipped: \(error)")
            }
        }
    }

    private func containsActiveJob(for directory: URL) -> Bool {
        let target = directory.standardizedFileURL
        return currentJob?.sessionDirectory.standardizedFileURL == target
            || queue.contains { $0.sessionDirectory.standardizedFileURL == target }
    }

    private func snapshot(for directory: URL) throws -> Job {
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        let transcriptData = try Data(contentsOf: transcriptURL)
        let transcript = try JSONDecoder().decode(SessionTranscript.self, from: transcriptData)
        let rawNotes = try readRawNotes(from: directory)
        let expectedSessionID = try SessionIdentity(sessionDirectory: directory).value
        guard rawNotes.sessionID == expectedSessionID else {
            throw CoordinatorError.rawNotesSessionMismatch(expected: expectedSessionID, found: rawNotes.sessionID)
        }
        let input = SummaryInput(
            transcriptSHA256: Self.sha256(transcriptData),
            transcriptSegmentCount: transcript.segments.count,
            rawNotesRevision: rawNotes.revision,
            rawNotesSHA256: try rawNotesDigest(rawNotes)
        )
        return Job(id: UUID(), sessionDirectory: directory, transcript: transcript, rawNotes: rawNotes, input: input)
    }

    private func drainIfNeeded() {
        guard drainTask == nil, !queue.isEmpty else { return }
        drainTask = Task { await self.drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            currentJob = job
            let name = job.sessionDirectory.lastPathComponent
            publish(.preparing(session: name, queued: queue.count))
            do {
                try Task.checkCancellation()
                // The snapshot has already decoded/validated the transcript
                // and notes. Generation receives only those frozen values.
                let brief: MeetingBrief
                if job.transcript.segments.isEmpty {
                    // This coverage result is owned by Quill, never by the
                    // model. It keeps the user informed without a zero-chunk
                    // extraction/reduction request.
                    log(job.sessionDirectory, "generation skipped: transcript has zero segments")
                    brief = try MeetingBrief.incompleteTranscript(input: job.input)
                } else {
                    publish(.generating(session: name, queued: queue.count))
                    log(job.sessionDirectory, "generation started (notes revision \(job.rawNotes.revision))")
                    let engine = engine
                    let task = Task {
                        try await engine.summarize(
                            transcript: job.transcript,
                            rawNotes: job.rawNotes,
                            input: job.input
                        )
                    }
                    generationTask = task
                    brief = try await task.value
                    generationTask = nil
                }
                guard !cancelledJobIDs.contains(job.id) else { throw CancellationError() }
                try MeetingBriefStore(sessionDirectory: job.sessionDirectory).write(
                    brief,
                    frozenTranscript: job.transcript,
                    expectedInput: job.input
                )
                let stale = try isStale(job)
                log(job.sessionDirectory, stale ? "generation complete (stale inputs)" : "generation complete")
                publish(.ready(session: name, stale: stale))
            } catch is CancellationError {
                generationTask = nil
                try? MeetingBriefStore(sessionDirectory: job.sessionDirectory).clearPending()
                log(job.sessionDirectory, "generation cancelled")
                publish(.cancelled(session: name))
            } catch {
                generationTask = nil
                if cancelledJobIDs.contains(job.id) {
                    try? MeetingBriefStore(sessionDirectory: job.sessionDirectory).clearPending()
                    log(job.sessionDirectory, "generation cancelled")
                    publish(.cancelled(session: name))
                } else {
                    // The process reached the provider and received a final
                    // failure (including timeout). This is no longer a crash-
                    // recovery case: clear the durable marker so a later app
                    // launch never retries model work without another explicit
                    // user action. The Retry button creates a fresh marker.
                    try? MeetingBriefStore(sessionDirectory: job.sessionDirectory).clearPending()
                    log(job.sessionDirectory, "generation failed: \(error)")
                    publish(.failed(session: name, message: String(describing: error)))
                }
            }
            cancelledJobIDs.remove(job.id)
            currentJob = nil
        }
        drainTask = nil
        publish(.idle)
        drainIfNeeded()
    }

    private func isStale(_ job: Job) throws -> Bool {
        let transcriptData = try Data(contentsOf: job.sessionDirectory.appendingPathComponent("transcript.json"))
        guard Self.sha256(transcriptData) == job.input.transcriptSHA256 else {
            return true
        }
        let currentNotes = try readRawNotes(from: job.sessionDirectory)
        let expectedSessionID = try SessionIdentity(sessionDirectory: job.sessionDirectory).value
        guard currentNotes.sessionID == expectedSessionID else { return true }
        if let rawNotesSHA256 = job.input.rawNotesSHA256 {
            return try rawNotesDigest(currentNotes) != rawNotesSHA256
        }
        return currentNotes.revision != job.rawNotes.revision
    }

    /// An untouched session has no raw-notes file because `SessionNoteStore`
    /// deliberately avoids creating one until the first edit. Treat it as the
    /// immutable empty revision-zero document without writing that file.
    private func readRawNotes(from directory: URL) throws -> RawMeetingNotes {
        let url = directory.appendingPathComponent("raw-notes.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return try RawMeetingNotes(
                sessionID: SessionIdentity(sessionDirectory: directory).value,
                revision: 0,
                template: "general",
                updatedAt: "",
                notes: []
            )
        }
        return try JSONDecoder().decode(RawMeetingNotes.self, from: Data(contentsOf: url))
    }

    private func rawNotesDigest(_ rawNotes: RawMeetingNotes) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.sha256(try encoder.encode(rawNotes))
    }

    private func publish(_ state: State) {
        self.state = state
        statusHandler?(state)
    }

    private func log(_ directory: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = directory.appendingPathComponent("brief.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
