import Foundation
import Testing

@testable import quill

private func transcript(_ segments: [(String, Int, Int, String)]) throws -> SessionTranscript {
    try SessionTranscript(
        engine: "fixture", model: "fixture", createdAt: "2026-09-02T10:00:00Z",
        speakerLabels: true, timestamps: true,
        segments: segments.enumerated().map { index, entry in
            .init(id: SessionTranscript.stableSegmentID(for: index), speaker: entry.0, startMS: entry.1, endMS: entry.2, text: entry.3)
        }
    )
}

@Test func contextSelectsSegmentsOverlappingTheWindowInOrder() throws {
    let source = try transcript([
        ("them", 0, 5_000, "opening"),
        ("me", 40_000, 50_000, "before the note"),
        ("them", 58_000, 62_000, "החלטנו להמשיך עם הגרסה המקומית"),
        ("me", 75_000, 79_000, "after the note"),
        ("them", 200_000, 205_000, "far later"),
    ])
    let context = MeetingNoteContext.around(capturedAtMS: 60_000, in: source)
    #expect(context.isNearestFallback == false)
    #expect(context.lines.map(\.segmentID) == ["s000002", "s000003", "s000004"])
    #expect(context.lines[1].text == "החלטנו להמשיך עם הגרסה המקומית")
}

@Test func contextKeepsTheLinesClosestToTheNoteWhenTheWindowIsCrowded() throws {
    let crowded = try transcript((0..<20).map { index in ("me", 30_000 + index * 2_000, 31_000 + index * 2_000, "line \(index)") })
    let context = MeetingNoteContext.around(capturedAtMS: 50_000, in: crowded, maxLines: 4)
    #expect(context.lines.count == 4)
    #expect(context.lines.map(\.startMS) == context.lines.map(\.startMS).sorted())
}

@Test func contextFallsBackToTheNearestSegmentWhenNothingOverlaps() throws {
    let sparse = try transcript([("them", 0, 2_000, "hello"), ("me", 500_000, 503_000, "much later")])
    let context = MeetingNoteContext.around(capturedAtMS: 300_000, in: sparse)
    #expect(context.isNearestFallback == true)
    #expect(context.lines.map(\.segmentID) == ["s000002"])
}

@Test func contextOfAnEmptyTranscriptHasNoLines() throws {
    let context = MeetingNoteContext.around(capturedAtMS: 10_000, in: try transcript([]))
    #expect(context.lines.isEmpty)
    #expect(context.isNearestFallback == false)
}

@Test func clockFormatsMeetingRelativeTimes() {
    #expect(MeetingNoteContext.clock(0) == "0:00")
    #expect(MeetingNoteContext.clock(61_000) == "1:01")
    #expect(MeetingNoteContext.clock(3_725_000) == "1:02:05")
    #expect(MeetingNoteContext.clock(-5) == "0:00")
}
