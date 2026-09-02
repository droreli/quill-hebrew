import Foundation

/// Where the canonical transcript stands for the session bound to the pad.
/// Every case is derived from durable facts (files on disk, the coordinator's
/// published status, config), never from timers or guesses. Quill has no live
/// transcription, so a recording session is always `.afterRecording`.
enum MeetingTranscriptAvailability: Equatable, Sendable {
    case afterRecording
    case pending
    case transcribing
    case failed
    case disabled
    case ready(segmentCount: Int)
}

/// The honest lifecycle phase the meeting pad is in.
enum MeetingPadLifecycle: Equatable, Sendable {
    case unbound
    case recording(startedAt: Date)
    case stopped(transcript: MeetingTranscriptAvailability)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var transcript: MeetingTranscriptAvailability? {
        switch self {
        case .unbound: nil
        case .recording: .afterRecording
        case let .stopped(transcript): transcript
        }
    }

    var transcriptIsReady: Bool {
        if case .ready = transcript { return true }
        return false
    }

    func headline(elapsed: String? = nil) -> String {
        switch self {
        case .unbound:
            "No meeting bound"
        case .recording:
            "Recording · \(elapsed ?? "0:00")"
        case let .stopped(transcript):
            switch transcript {
            case .afterRecording: "Stopped"
            case .pending: "Stopped · waiting for local transcription"
            case .transcribing: "Transcribing locally…"
            case .failed: "Transcription failed"
            case .disabled: "Transcription is off"
            case let .ready(segmentCount):
                "Transcript ready · \(segmentCount) segment\(segmentCount == 1 ? "" : "s")"
            }
        }
    }

    var detail: String {
        switch self {
        case .unbound:
            "Start a recording, or open the latest session, to take notes."
        case .recording:
            "Notes are stamped as you write. The transcript arrives after you stop."
        case let .stopped(transcript):
            switch transcript {
            case .afterRecording:
                "The transcript arrives after transcription finishes."
            case .pending, .transcribing:
                "Keep editing notes. Nothing leaves this Mac."
            case .failed:
                "See transcribe.log in the session folder, then run quill retranscribe."
            case .disabled:
                "Enable transcription in config to get a transcript and an AI brief."
            case .ready:
                "Select a note to see what was said around it."
            }
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .unbound: "No meeting is bound to the notes pad."
        case .recording: "Recording in progress. Transcript will be created after recording stops."
        case let .stopped(transcript):
            switch transcript {
            case .afterRecording: "Recording stopped."
            case .pending: "Recording stopped. Waiting for local transcription."
            case .transcribing: "Recording stopped. Transcribing locally."
            case .failed: "Transcription failed. See transcribe log in the session folder."
            case .disabled: "Transcription is disabled in configuration."
            case let .ready(segmentCount): "Transcript ready with \(segmentCount) segments."
            }
        }
    }

    var briefAvailability: MeetingBriefAvailability {
        MeetingBriefAvailability(isRecording: isRecording, transcriptReady: transcriptIsReady)
    }
}

/// What the pad's primary AI action can honestly offer right now.
enum MeetingEnhancementAvailability: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case none
        case openProviderSetup
        case generateBrief
        case openBrief
    }

    case unbound
    case recording
    case waitingForTranscript
    case transcriptFailed
    case transcriptionDisabled
    case providerDisabled
    case ready
    case briefAvailable

    init(lifecycle: MeetingPadLifecycle, providerEnabled: Bool, briefExists: Bool) {
        switch lifecycle {
        case .unbound:
            self = .unbound
        case .recording:
            self = .recording
        case let .stopped(transcript):
            switch transcript {
            case .afterRecording, .pending, .transcribing:
                self = .waitingForTranscript
            case .failed:
                self = .transcriptFailed
            case .disabled:
                self = .transcriptionDisabled
            case .ready:
                if briefExists {
                    self = .briefAvailable
                } else if providerEnabled {
                    self = .ready
                } else {
                    self = .providerDisabled
                }
            }
        }
    }

    var action: Action {
        switch self {
        case .unbound, .recording, .waitingForTranscript, .transcriptFailed, .transcriptionDisabled: .none
        case .providerDisabled: .openProviderSetup
        case .ready: .generateBrief
        case .briefAvailable: .openBrief
        }
    }

    var isEnabled: Bool { action != .none }

    var buttonTitle: String {
        switch self {
        case .unbound, .recording, .waitingForTranscript, .transcriptFailed, .transcriptionDisabled, .ready:
            "Enhance with AI brief"
        case .providerDisabled:
            "Set up local AI…"
        case .briefAvailable:
            "Open AI brief"
        }
    }

    var guidance: String {
        switch self {
        case .unbound:
            "Bind a meeting first."
        case .recording:
            "Available after recording and local transcription finish."
        case .waitingForTranscript:
            "Available once the local transcript is ready."
        case .transcriptFailed:
            "Not available: transcription failed for this session."
        case .transcriptionDisabled:
            "Not available: transcription is off in config."
        case .providerDisabled:
            "Enable the local LM Studio provider to generate a brief from the transcript and your notes."
        case .ready:
            "Generates a local brief from the transcript and your notes. Your notes stay unchanged."
        case .briefAvailable:
            "A brief exists for this session. Regenerate from the brief window if notes changed."
        }
    }
}

/// The two decisions the pad shows, resolved together from one set of facts.
struct MeetingPadStatus: Equatable, Sendable {
    enum TranscriptionActivity: Equatable, Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    struct Facts: Equatable, Sendable {
        var sessionName: String?
        var isRecording: Bool
        var startedAt: Date?
        var hasCompletedMeta: Bool
        var transcriptSegmentCount: Int?
        var transcriptionActivity: TranscriptionActivity
        var transcriptionEnabled: Bool
        var providerEnabled: Bool
        var briefExists: Bool

        init(
            sessionName: String? = nil,
            isRecording: Bool = false,
            startedAt: Date? = nil,
            hasCompletedMeta: Bool = false,
            transcriptSegmentCount: Int? = nil,
            transcriptionActivity: TranscriptionActivity = .idle,
            transcriptionEnabled: Bool = true,
            providerEnabled: Bool = false,
            briefExists: Bool = false
        ) {
            self.sessionName = sessionName
            self.isRecording = isRecording
            self.startedAt = startedAt
            self.hasCompletedMeta = hasCompletedMeta
            self.transcriptSegmentCount = transcriptSegmentCount
            self.transcriptionActivity = transcriptionActivity
            self.transcriptionEnabled = transcriptionEnabled
            self.providerEnabled = providerEnabled
            self.briefExists = briefExists
        }
    }

    let lifecycle: MeetingPadLifecycle
    let enhancement: MeetingEnhancementAvailability

    static let unbound = MeetingPadStatus(lifecycle: .unbound, enhancement: .unbound)

    static func resolve(_ facts: Facts) -> MeetingPadStatus {
        guard let sessionName = facts.sessionName else { return .unbound }
        let lifecycle: MeetingPadLifecycle
        if facts.isRecording {
            lifecycle = .recording(startedAt: facts.startedAt ?? Date())
        } else if let segmentCount = facts.transcriptSegmentCount {
            lifecycle = .stopped(transcript: .ready(segmentCount: segmentCount))
        } else if !facts.transcriptionEnabled {
            lifecycle = .stopped(transcript: .disabled)
        } else {
            switch facts.transcriptionActivity {
            case let .transcribing(session, _) where session == sessionName:
                lifecycle = .stopped(transcript: .transcribing)
            case let .failed(session) where session == sessionName:
                lifecycle = .stopped(transcript: .failed)
            case .idle, .transcribing, .failed:
                lifecycle = .stopped(transcript: facts.hasCompletedMeta ? .pending : .afterRecording)
            }
        }
        return MeetingPadStatus(
            lifecycle: lifecycle,
            enhancement: MeetingEnhancementAvailability(
                lifecycle: lifecycle,
                providerEnabled: facts.providerEnabled,
                briefExists: facts.briefExists
            )
        )
    }
}
