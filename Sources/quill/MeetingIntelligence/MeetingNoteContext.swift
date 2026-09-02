import Foundation

/// Deterministic "what was said around this note" lookup against the
/// canonical transcript. It is plain time-window selection, not a model, and
/// it never touches audio. The pad shows it once `transcript.json` exists.
struct MeetingNoteContext: Equatable, Sendable {
    struct Line: Equatable, Sendable, Identifiable {
        let segmentID: String
        let speaker: String
        let startMS: Int
        let text: String

        var id: String { segmentID }
    }

    let capturedAtMS: Int
    let lines: [Line]
    /// True when nothing overlapped the window and the closest segment was
    /// used instead, so the UI can say "nearest" rather than "around".
    let isNearestFallback: Bool

    static let defaultBeforeMS = 45_000
    static let defaultAfterMS = 20_000
    static let defaultMaxLines = 8

    /// Segments overlapping `[capturedAtMS - before, capturedAtMS + after]`,
    /// in chronological order. When more than `maxLines` overlap, the lines
    /// closest to the note's moment are kept. When none overlap, the single
    /// nearest segment is returned as a fallback.
    static func around(
        capturedAtMS: Int,
        in transcript: SessionTranscript,
        beforeMS: Int = defaultBeforeMS,
        afterMS: Int = defaultAfterMS,
        maxLines: Int = defaultMaxLines
    ) -> MeetingNoteContext {
        let anchor = max(0, capturedAtMS)
        let windowStart = max(0, anchor - max(0, beforeMS))
        let windowEnd = anchor + max(0, afterMS)
        let overlapping = transcript.segments.filter { segment in
            segment.endMS >= windowStart && segment.startMS <= windowEnd
        }

        if overlapping.isEmpty {
            guard let nearest = transcript.segments.min(by: {
                distance(from: anchor, to: $0) < distance(from: anchor, to: $1)
            }) else {
                return MeetingNoteContext(capturedAtMS: anchor, lines: [], isNearestFallback: false)
            }
            return MeetingNoteContext(capturedAtMS: anchor, lines: [line(nearest)], isNearestFallback: true)
        }

        let limit = max(1, maxLines)
        let kept: [SessionTranscript.Segment]
        if overlapping.count > limit {
            kept = Array(
                overlapping
                    .sorted { distance(from: anchor, to: $0) < distance(from: anchor, to: $1) }
                    .prefix(limit)
            )
            .sorted { $0.startMS < $1.startMS }
        } else {
            kept = overlapping
        }
        return MeetingNoteContext(capturedAtMS: anchor, lines: kept.map(line), isNearestFallback: false)
    }

    private static func distance(from anchor: Int, to segment: SessionTranscript.Segment) -> Int {
        if anchor < segment.startMS { return segment.startMS - anchor }
        if anchor > segment.endMS { return anchor - segment.endMS }
        return 0
    }

    private static func line(_ segment: SessionTranscript.Segment) -> Line {
        Line(segmentID: segment.id, speaker: segment.speaker, startMS: segment.startMS, text: segment.text)
    }

    /// `m:ss` or `h:mm:ss`, matching the transcript reading view.
    static func clock(_ milliseconds: Int) -> String {
        let total = max(0, milliseconds) / 1_000
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
