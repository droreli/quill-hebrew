import Foundation

/// A durable, local-only view of every recording that has finished capture.
/// Unlike `CompletedTranscriptSessions`, this intentionally includes sessions
/// that still await a transcript so the library can show their real state.
struct MeetingLibrarySessions {
    struct Audio: Equatable, Sendable {
        let microphoneAvailable: Bool
        let systemAvailable: Bool
        let listeningCopyAvailable: Bool

        var sourceSummary: String {
            switch (microphoneAvailable, systemAvailable) {
            case (true, true): "Microphone and system tracks available"
            case (true, false): "Microphone track available; system track is missing"
            case (false, true): "System track available; microphone track is missing"
            case (false, false): "No source tracks found"
            }
        }
    }

    enum Transcript: Equatable, Sendable {
        case ready(segmentCount: Int)
        case waiting
        case unreadable

        var summary: String {
            switch self {
            case let .ready(segmentCount): "Transcript ready · \(segmentCount) segment\(segmentCount == 1 ? "" : "s")"
            case .waiting: "Transcript not ready yet"
            case .unreadable: "Transcript file needs attention"
            }
        }

        var canBrief: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    struct Session: Identifiable, Equatable, Sendable {
        let directory: URL
        let title: String
        let startedAt: Date?
        let endedAt: Date?
        let durationSeconds: Int?
        let transcript: Transcript
        let audio: Audio
        let hasBrief: Bool

        var id: URL { directory.standardizedFileURL }
    }

    struct Snapshot: Equatable, Sendable {
        let sessions: [Session]
        let errorMessage: String?
    }

    static func snapshot(in root: URL, fileManager: FileManager = .default) -> Snapshot {
        guard fileManager.fileExists(atPath: root.path) else {
            return Snapshot(sessions: [], errorMessage: nil)
        }
        do {
            let directories = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            let sessions = directories.compactMap { session(from: $0, fileManager: fileManager) }
                .sorted { $0.title > $1.title }
            return Snapshot(sessions: sessions, errorMessage: nil)
        } catch {
            return Snapshot(sessions: [], errorMessage: "Could not read the recordings folder: \(error.localizedDescription)")
        }
    }

    private static func session(from directory: URL, fileManager: FileManager) -> Session? {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let metaURL = directory.appendingPathComponent("meta.json")
        guard fileManager.fileExists(atPath: metaURL.path) else { return nil }

        let metadata = (try? Data(contentsOf: metaURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        let dateFormatter = ISO8601DateFormatter()
        let files = metadata["files"] as? [String: String] ?? [:]
        let mic = files["mic"] ?? "mic.caf"
        let system = files["system"] ?? "system.caf"
        let mixed = files["mixed"] ?? "mixed.m4a"
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        let transcript: Transcript
        if !fileManager.fileExists(atPath: transcriptURL.path) {
            transcript = .waiting
        } else if let data = try? Data(contentsOf: transcriptURL),
                  let decoded = try? JSONDecoder().decode(SessionTranscript.self, from: data) {
            transcript = .ready(segmentCount: decoded.segments.count)
        } else {
            transcript = .unreadable
        }

        return Session(
            directory: directory,
            title: directory.lastPathComponent,
            startedAt: (metadata["started"] as? String).flatMap(dateFormatter.date(from:)),
            endedAt: (metadata["ended"] as? String).flatMap(dateFormatter.date(from:)),
            durationSeconds: metadata["duration_seconds"] as? Int,
            transcript: transcript,
            audio: Audio(
                microphoneAvailable: fileManager.fileExists(atPath: directory.appendingPathComponent(mic).path),
                systemAvailable: fileManager.fileExists(atPath: directory.appendingPathComponent(system).path),
                listeningCopyAvailable: fileManager.fileExists(atPath: directory.appendingPathComponent(mixed).path)
            ),
            hasBrief: fileManager.fileExists(atPath: MeetingBriefStore(sessionDirectory: directory).briefURL.path)
        )
    }
}
