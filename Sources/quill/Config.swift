import Foundation

enum TranscriptionLanguage: String, CaseIterable, Sendable {
    case automatic
    case hebrew
    case english
}

enum TranscriptionEngineChoice: String, CaseIterable, Sendable {
    /// Tamlil's pinned Hebrew Whisper Large V3 Turbo MLX runtime.
    case hebrewMLX = "mlx-hebrew"
    /// FluidAudio's local Core ML Parakeet engine (English).
    case parakeet
    /// Tamlil's local faster-whisper Hebrew fallback.
    case hebrewCPU = "hebrew-cpu"
}

struct RecordingOptions: Sendable {
    var output: Config.RecordingOutput
    var language: TranscriptionLanguage
    var engine: TranscriptionEngineChoice
    var showTimestamps: Bool
    var showSpeakerLabels: Bool
}

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "export_mixed_audio": false,
///       "speaker_labels": false,
///       "transcription": { "enabled": true, "engine": "mlx-hebrew" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    enum RecordingOutput: String, Sendable {
        /// Keep and transcribe the original two-track workflow. This is the
        /// default because it remains intelligible when people overlap.
        case separate
        /// Keep the two-track transcript and additionally render a listening
        /// copy at mixed.m4a. The mixed file is never the primary transcript.
        case separateWithMixedExport

        static func parse(_ value: String?) -> Self {
            // "mixed" was accepted by an unreleased build. Retain it as a
            // compatibility alias, but never use it as the primary transcript.
            switch value?.lowercased() {
            case "mixed", "separate-with-mixed-export": .separateWithMixedExport
            default: .separate
            }
        }
    }

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. The local Hebrew MLX engine is preferred when
    /// its already-provisioned runtime is usable; Parakeet remains a local
    /// English fallback.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "mlx-hebrew"
    }

    static func transcriptionEngineChoice() -> TranscriptionEngineChoice {
        TranscriptionEngineChoice(rawValue: transcriptionEngine().lowercased()) ?? .hebrewMLX
    }

    static func transcriptionLanguage() -> TranscriptionLanguage {
        let raw = transcription()?["language"] as? String ?? "automatic"
        return TranscriptionLanguage(rawValue: raw.lowercased()) ?? .automatic
    }

    /// Timestamps always remain in transcript.json for accurate ordering.
    /// This controls whether they are shown in the reading-oriented Markdown.
    static func showTimestamps() -> Bool {
        transcription()?["timestamps"] as? Bool ?? true
    }

    static func recordingOutput() -> RecordingOutput {
        let config = load()
        if config?["export_mixed_audio"] as? Bool == true {
            return .separateWithMixedExport
        }
        return RecordingOutput.parse(config?["recording_output"] as? String)
    }

    /// The readable Markdown transcript is chronological and intentionally
    /// label-free by default. transcript.json always preserves `me`/`them`
    /// for automation and for users who prefer the original workflow.
    static func showSpeakerLabels() -> Bool {
        load()?["speaker_labels"] as? Bool ?? false
    }

    static func recordingOptions(outputOverride: RecordingOutput? = nil) -> RecordingOptions {
        RecordingOptions(
            output: outputOverride ?? recordingOutput(),
            language: transcriptionLanguage(),
            engine: transcriptionEngineChoice(),
            showTimestamps: showTimestamps(),
            showSpeakerLabels: showSpeakerLabels()
        )
    }

    /// Persist the choices made in the controls window. This deliberately
    /// merges only the recording preferences, preserving local engine paths,
    /// hooks, and any other user-managed configuration keys.
    static func saveRecordingDefaults(_ options: RecordingOptions) throws {
        var config = load() ?? [:]
        var transcription = config["transcription"] as? [String: Any] ?? [:]

        transcription["language"] = options.language.rawValue
        transcription["engine"] = options.engine.rawValue
        transcription["timestamps"] = options.showTimestamps
        config["transcription"] = transcription
        config["speaker_labels"] = options.showSpeakerLabels
        config["export_mixed_audio"] = options.output == .separateWithMixedExport

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: path, options: .atomic)
    }

    /// The proven Tamlil runtime lives here by default. Both the interpreter
    /// and model location can be overridden for another local macOS account;
    /// no value is ever sent to a service.
    static func mlxPython() -> URL {
        if let configured = transcription()?["mlx_python"] as? String, !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("venvs/mlx-whisper/bin/python")
    }

    static func mlxModelDirectory() -> URL {
        if let configured = transcription()?["mlx_model_dir"] as? String, !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".cache/huggingface/hub/models--mlx-community--ivrit-ai-whisper-large-v3-turbo-mlx/snapshots/53ad8c6cd8b32eb0303f093a404ae13c1b1d567f",
                isDirectory: true
            )
    }

    /// `auto` lets the Hebrew Whisper model preserve English turns in a mixed
    /// meeting. Set `he` in config to force Hebrew-only decoding.
    static func mlxLanguage() -> String {
        let value = transcription()?["mlx_language"] as? String ?? "auto"
        return value == "he" ? "he" : "auto"
    }

    static func cpuScript() -> URL {
        if let configured = transcription()?["cpu_script"] as? String, !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin/transcribe-hib-live")
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
