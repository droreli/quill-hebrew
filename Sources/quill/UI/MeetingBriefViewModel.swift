import Foundation

/// One shared readiness decision for every place that can open a meeting
/// brief. A brief is a post-transcript artifact: it never reads live audio and
/// must not look actionable while recording or transcription is still active.
enum MeetingBriefAvailability: Equatable {
    case recording
    case waitingForTranscript
    case ready

    init(isRecording: Bool, transcriptReady: Bool) {
        if isRecording {
            self = .recording
        } else if transcriptReady {
            self = .ready
        } else {
            self = .waitingForTranscript
        }
    }

    var canOpen: Bool { self == .ready }

    var buttonTitle: String {
        switch self {
        case .recording: "Meeting brief — after recording"
        case .waitingForTranscript: "Meeting brief — waiting for transcript"
        case .ready: "Meeting brief…"
        }
    }

    var guidance: String {
        switch self {
        case .recording:
            "Capture notes now. AI Brief unlocks after you stop recording and transcription finishes."
        case .waitingForTranscript:
            "Transcribing locally… AI Brief unlocks automatically when the transcript is ready."
        case .ready:
            "Transcript ready. Generate a local AI brief whenever you choose."
        }
    }
}

/// Read-only state supplied by the post-meeting coordinator.  This deliberately
/// contains no generation, persistence, transcript, or note-editing behavior.
@MainActor
final class MeetingBriefViewModel {
    enum State: Equatable {
        case missing
        case processing(message: String)
        case failed(message: String)
        case stale(MeetingBrief)
        case ready(MeetingBrief)

        var title: String {
            switch self {
            case .missing: "Brief not generated"
            case .processing: "Generating locally"
            case .failed: "Generation needs attention"
            case .stale: "Brief needs regeneration"
            case let .ready(brief) where brief.inputs.transcriptSegmentCount == 0:
                "No transcript to summarize"
            case .ready: "Meeting brief ready"
            }
        }

        var accessibilityDescription: String {
            switch self {
            case .missing:
                "No meeting brief has been generated."
            case let .processing(message):
                "Meeting brief generation is in progress. \(message)"
            case let .failed(message):
                "Meeting brief generation failed. \(message)"
            case .stale:
                "A previous brief is available, but its source notes or transcript have changed."
            case let .ready(brief) where brief.inputs.transcriptSegmentCount == 0:
                "The transcript contains no speech segments, so the local AI model was not contacted and no meeting summary was generated."
            case .ready:
                "A generated meeting brief is ready to review."
            }
        }

        var brief: MeetingBrief? {
            switch self {
            case let .stale(brief), let .ready(brief): brief
            case .missing, .processing, .failed: nil
            }
        }

        var isProcessing: Bool {
            if case .processing = self { return true }
            return false
        }

        var hasTranscriptCoverage: Bool {
            guard let brief else { return true }
            return brief.inputs.transcriptSegmentCount > 0
        }
    }

    private(set) var state: State {
        didSet { notifyChange() }
    }
    private(set) var rawNotes: RawMeetingNotes? {
        didSet { notifyChange() }
    }
    private(set) var sessionDirectory: URL? {
        didSet { notifyChange() }
    }
    private var isBatchUpdating = false

    /// The window controller owns this observation hook. It is intentionally
    /// UI-only, so callers can update the presentation without coupling the
    /// meeting pipeline to AppKit.
    var onChange: (() -> Void)?

    init(state: State = .missing, rawNotes: RawMeetingNotes? = nil, sessionDirectory: URL? = nil) {
        self.state = state
        self.rawNotes = rawNotes
        self.sessionDirectory = sessionDirectory
    }

    func update(state: State, rawNotes: RawMeetingNotes?, sessionDirectory: URL?) {
        // Batch changes so one coordinator update causes one visual refresh.
        isBatchUpdating = true
        self.state = state
        self.rawNotes = rawNotes
        self.sessionDirectory = sessionDirectory
        isBatchUpdating = false
        notifyChange()
    }

    func updateState(_ state: State) {
        self.state = state
    }

    func updateRawNotes(_ rawNotes: RawMeetingNotes?) {
        self.rawNotes = rawNotes
    }

    private func notifyChange() {
        guard !isBatchUpdating else { return }
        onChange?()
    }
}
