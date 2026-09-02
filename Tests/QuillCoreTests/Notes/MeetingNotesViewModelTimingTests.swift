import Foundation
import Testing

@testable import quill

private func noteSnapshot(_ notes: [RawMeetingNotes.Note]) throws -> RawMeetingNotes {
    try RawMeetingNotes(sessionID: "session", revision: 1, template: "general", updatedAt: "2026-09-02T10:00:00Z", notes: notes)
}

private func note(_ id: String, text: String, at capturedAtMS: Int) -> RawMeetingNotes.Note {
    RawMeetingNotes.Note(id: id, text: text, capturedAtMS: capturedAtMS, createdAt: "2026-09-02T10:00:00Z", updatedAt: "2026-09-02T10:00:00Z")
}

@MainActor
@Test func freshDraftIsStampedWhenWritingStartsNotWhenSaved() {
    var now = 12_000
    let viewModel = MeetingNotesViewModel()
    var command: MeetingNotesCommand?
    viewModel.onCommand = { command = $0 }
    viewModel.bind(sessionID: "session", clock: { now })
    viewModel.updateDraft("ה")
    #expect(viewModel.draftCapturedAtMS == 12_000)
    now = 95_000
    viewModel.updateDraft("החלטנו להמשיך")
    viewModel.saveDraft()
    #expect(command == .saveNote(sessionID: "session", noteID: nil, text: "החלטנו להמשיך", capturedAtMS: 12_000))
}

@MainActor
@Test func emptyingTheDraftForgetsItsStartTime() {
    var now = 5_000
    let viewModel = MeetingNotesViewModel()
    viewModel.bind(sessionID: "session", clock: { now })
    viewModel.updateDraft("first")
    viewModel.updateDraft("")
    #expect(viewModel.draftCapturedAtMS == nil)
    now = 9_000
    viewModel.updateDraft("second")
    #expect(viewModel.draftCapturedAtMS == 9_000)
}

@MainActor
@Test func editingAnExistingNoteKeepsItsOriginalTime() throws {
    let viewModel = MeetingNotesViewModel()
    var command: MeetingNotesCommand?
    viewModel.onCommand = { command = $0 }
    viewModel.bind(sessionID: "session", snapshot: try noteSnapshot([note("n1", text: "cue", at: 30_000)]), clock: { 999_000 })
    viewModel.selectNote(id: "n1")
    viewModel.updateDraft("cue, expanded")
    viewModel.saveDraft()
    #expect(command == .saveNote(sessionID: "session", noteID: "n1", text: "cue, expanded", capturedAtMS: nil))
}

@MainActor
@Test func timestampMarkerAnchorsAFreshDraft() {
    let viewModel = MeetingNotesViewModel()
    viewModel.bind(sessionID: "session", clock: { 42_000 })
    viewModel.insertTimestampMarker("[0:42]")
    #expect(viewModel.draftCapturedAtMS == 42_000)
}

@MainActor
@Test func withoutAClockTheCoordinatorStampsTheNote() {
    let viewModel = MeetingNotesViewModel()
    var command: MeetingNotesCommand?
    viewModel.onCommand = { command = $0 }
    viewModel.bind(sessionID: "session")
    viewModel.updateDraft("plain")
    viewModel.saveDraft()
    #expect(command == .saveNote(sessionID: "session", noteID: nil, text: "plain", capturedAtMS: nil))
}

@MainActor
@Test func statusAndTranscriptApplyOnlyToTheBoundSession() throws {
    let viewModel = MeetingNotesViewModel()
    let ready = MeetingPadStatus.resolve(.init(sessionName: "s", transcriptSegmentCount: 2, providerEnabled: true))
    viewModel.setStatus(ready)
    #expect(viewModel.status == .unbound)
    viewModel.bind(sessionID: "session", snapshot: try noteSnapshot([note("n1", text: "cue", at: 61_000)]))
    viewModel.setStatus(ready)
    let transcript = try SessionTranscript(engine: "fixture", model: "fixture", createdAt: "2026-09-02T10:00:00Z", speakerLabels: true, timestamps: true, segments: [
        .init(id: "s000001", speaker: "them", startMS: 55_000, endMS: 60_000, text: "נדבר על התקציב"),
        .init(id: "s000002", speaker: "me", startMS: 62_000, endMS: 65_000, text: "ok"),
    ])
    #expect(viewModel.acceptTranscript(transcript, sessionID: "other") == false)
    #expect(viewModel.acceptTranscript(transcript, sessionID: "session"))
    viewModel.selectNote(id: "n1")
    #expect(viewModel.selectedNoteContext?.lines.map(\.segmentID) == ["s000001", "s000002"])
    viewModel.unbind()
    #expect(viewModel.status == .unbound)
}
