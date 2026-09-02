import ArgumentParser
import Testing

@testable import quill

@Test func appRuntimeUsesSynchronousCommandRoot() {
    #expect(!(Quill.self is any AsyncParsableCommand.Type))
    #expect(!(Run.self is any AsyncParsableCommand.Type))
    #expect(!(Brief.self is any AsyncParsableCommand.Type))
}

@MainActor
@Test func notesBindingFailureRemainsVisibleWhileUnbound() {
    let viewModel = MeetingNotesViewModel()
    viewModel.setSaveState(.failed(message: "fixture failure"))

    #expect(viewModel.isBound == false)
    #expect(viewModel.saveState == .failed(message: "fixture failure"))
}

@Test func meetingBriefUnlocksOnlyAfterRecordingAndTranscriptionFinish() {
    let duringRecording = MeetingBriefAvailability(isRecording: true, transcriptReady: true)
    let transcribing = MeetingBriefAvailability(isRecording: false, transcriptReady: false)
    let ready = MeetingBriefAvailability(isRecording: false, transcriptReady: true)

    #expect(duringRecording == .recording)
    #expect(duringRecording.canOpen == false)
    #expect(transcribing == .waitingForTranscript)
    #expect(transcribing.canOpen == false)
    #expect(ready == .ready)
    #expect(ready.canOpen == true)
}

@MainActor
@Test func emptyTranscriptBriefClearlySaysLocalModelWasNotUsed() throws {
    let input = SummaryInput(
        transcriptSHA256: "empty",
        transcriptSegmentCount: 0,
        rawNotesRevision: 3
    )
    let brief = try MeetingBrief.incompleteTranscript(
        input: input,
        createdAt: "2026-09-01T14:05:10Z"
    )
    let state = MeetingBriefViewModel.State.ready(brief)

    #expect(state.title == "No transcript to summarize")
    #expect(state.hasTranscriptCoverage == false)
    #expect(state.accessibilityDescription.contains("local AI model was not contacted"))
}

@MainActor
@Test func successfulQuickNoteSaveClearsTheEditorWithoutLosingTheNote() throws {
    let viewModel = MeetingNotesViewModel()
    var command: MeetingNotesCommand?
    viewModel.onCommand = { command = $0 }
    viewModel.bind(sessionID: "session")
    viewModel.updateDraft("החלטנו להמשיך")
    viewModel.saveDraft()

    #expect(command == .saveNote(sessionID: "session", noteID: nil, text: "החלטנו להמשיך", capturedAtMS: nil))
    #expect(viewModel.draftText == "החלטנו להמשיך")

    let saved = RawMeetingNotes.Note(
        id: "note-1",
        text: "החלטנו להמשיך",
        capturedAtMS: 12_000,
        createdAt: "2026-09-01T12:00:00Z",
        updatedAt: "2026-09-01T12:00:00Z"
    )
    let snapshot = try RawMeetingNotes(
        sessionID: "session",
        revision: 1,
        template: "general",
        updatedAt: "2026-09-01T12:00:00Z",
        notes: [saved]
    )
    #expect(viewModel.accept(snapshot: snapshot))
    #expect(viewModel.draftText.isEmpty)
    #expect(viewModel.selectedNoteID == nil)
    #expect(viewModel.notes == [saved])
}
