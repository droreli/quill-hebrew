import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var engineChoice: TranscriptionEngineChoice?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    init() {}

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Explicit recovery path for a completed session. Unlike the startup
    /// scan, this does not rely on queue timing and never touches raw audio.
    func retranscribe(_ sessionDir: URL) async throws {
        try await transcribe(sessionDir)
        await engine?.release()
        engine = nil
        engineChoice = nil
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                notifyUser(title: "quill — transcript ready", body: dir.lastPathComponent)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "quill — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine(for: meta)

        if meta.exportMixedAudio {
            do {
                let mixed = dir.appendingPathComponent("mixed.m4a")
                if !FileManager.default.fileExists(atPath: mixed.path) {
                    log(dir, "exporting optional mixed.m4a (clean tracks remain primary for transcription)")
                    try await MixedAudioExporter.export(
                        inputs: meta.tracks.map {
                            MixedAudioInput(
                                url: dir.appendingPathComponent($0.file),
                                offset: TimeInterval($0.offsetMs) / 1000
                            )
                        },
                        to: mixed
                    )
                    try SessionMeta.recordMixedFile(in: dir)
                }
            } catch {
                // A listening-copy failure must never cost the resilient
                // separate-track transcript.
                log(dir, "optional mixed-audio export failed: \(error)")
            }
        }

        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            speaker_labels: meta.showSpeakerLabels,
            timestamps: meta.showTimestamps,
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    private func preparedEngine(for meta: SessionMeta) async throws -> TranscriptionEngine {
        if let engine, engineChoice == meta.engine { return engine }
        await engine?.release()
        engine = nil
        engineChoice = nil

        if meta.engine == .parakeet {
            let engine = ParakeetEngine()
            try await engine.prepare()
            self.engine = engine
            self.engineChoice = .parakeet
            return engine
        }

        if meta.engine == .hebrewCPU {
            let engine = HebrewCPUWhisperEngine()
            try await engine.prepare()
            self.engine = engine
            self.engineChoice = .hebrewCPU
            return engine
        }

        do {
            let engine = MLXWhisperEngine(language: meta.language)
            try await engine.prepare()
            self.engine = engine
            self.engineChoice = .hebrewMLX
            return engine
        } catch {
            FileHandle.standardError.write(Data(
                "warning: Hebrew MLX unavailable (\(error)) — falling back to local English Parakeet\n".utf8
            ))
            let engine = ParakeetEngine()
            try await engine.prepare()
            self.engine = engine
            self.engineChoice = .parakeet
            return engine
        }
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
struct SessionMeta {
    struct Track: Sendable {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]
    let exportMixedAudio: Bool
    let showSpeakerLabels: Bool
    let showTimestamps: Bool
    let language: TranscriptionLanguage
    let engine: TranscriptionEngineChoice

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(
            tracks: tracks,
            exportMixedAudio: (json["export_mixed_audio"] as? Bool)
                ?? (Config.recordingOutput() == .separateWithMixedExport),
            showSpeakerLabels: json["speaker_labels"] as? Bool ?? Config.showSpeakerLabels(),
            showTimestamps: json["timestamps"] as? Bool ?? Config.showTimestamps(),
            language: TranscriptionLanguage(rawValue: json["transcription_language"] as? String ?? "")
                ?? Config.transcriptionLanguage(),
            engine: TranscriptionEngineChoice(rawValue: json["transcription_engine"] as? String ?? "")
                ?? Config.transcriptionEngineChoice()
        )
    }

    static func recordMixedFile(in dir: URL) throws {
        let url = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }
        files["mixed"] = "mixed.m4a"
        json["files"] = files
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
private struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let speaker_labels: Bool
    let timestamps: Bool
    let segments: [Segment]

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            let time = timestamps ? "[\(Self.clock(seg.start_ms))]" : ""
            let speaker = speaker_labels ? seg.speaker : ""
            let prefix = [time, speaker].filter { !$0.isEmpty }.joined(separator: " ")
            lines.append(prefix.isEmpty ? seg.text : "**\(prefix):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
