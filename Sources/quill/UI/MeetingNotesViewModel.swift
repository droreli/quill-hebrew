import Foundation

/// The small command surface the recording/session layer needs from the notes
/// UI. The UI never writes `raw-notes.json`, reads the wall clock, or talks to
/// audio capture; it reports intent and renders the next supplied snapshot.
enum MeetingNotesCommand: Sendable, Equatable {
    case selectTemplate(sessionID: String, template: String)
    case saveNote(sessionID: String, noteID: String?, text: String, capturedAtMS: Int?)
    case deleteNote(sessionID: String, noteID: String)
    case requestTimestampMarker(sessionID: String)
}

enum MeetingNoteTemplate: String, CaseIterable, Sendable {
    case general
    case decision
    case customerCall = "customer-call"
    case blank

    var title: String {
        switch self {
        case .general: "General"
        case .decision: "Decision"
        case .customerCall: "Customer call"
        case .blank: "Blank"
        }
    }

    /// A gentle starting point only. Existing draft text is never replaced
    /// when the user changes templates.
    var starterText: String {
        switch self {
        case .general:
            "# Notes\n- "
        case .decision:
            "# Decisions\n- \n\n# Open questions\n- "
        case .customerCall:
            "# Customer context\n- \n\n# Needs\n- \n\n# Next step\n- "
        case .blank:
            ""
        }
    }

    static func known(_ rawValue: String) -> MeetingNoteTemplate? {
        MeetingNoteTemplate(rawValue: rawValue)
    }
}

@MainActor
final class MeetingNotesViewModel {
    enum SaveState: Equatable {
        case unbound
        case waitingForSave
        case saved(updatedAt: String?)
        case failed(message: String)

        var accessibilityDescription: String {
            switch self {
            case .unbound: "No active meeting"
            case .waitingForSave: "Saving note locally"
            case let .saved(updatedAt):
                updatedAt.map { "Saved locally at \($0)" } ?? "Saved locally"
            case let .failed(message): "Notes were not saved: \(message)"
            }
        }
    }

    private(set) var sessionID: String?
    private(set) var snapshot: RawMeetingNotes?
    private(set) var saveState: SaveState = .unbound
    private(set) var selectedNoteID: String?
    private(set) var draftText = ""
    private(set) var selectedTemplate: MeetingNoteTemplate = .general
    private(set) var status: MeetingPadStatus = .unbound
    private(set) var transcript: SessionTranscript?
    private(set) var draftCapturedAtMS: Int?
    private var clearDraftAfterSave = false
    private var meetingClock: (() -> Int)?

    /// Set by the coordinator. It should enqueue the command off the UI path
    /// and later call `accept(snapshot:)` or `setSaveState(_:)` on this model.
    var onCommand: ((MeetingNotesCommand) -> Void)?
    var onChange: (() -> Void)?

    var notes: [RawMeetingNotes.Note] { snapshot?.notes ?? [] }
    var isBound: Bool { sessionID != nil }
    var hasSelectedNote: Bool { selectedNoteID != nil }
    var selectedNote: RawMeetingNotes.Note? {
        guard let selectedNoteID else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }

    var selectedNoteContext: MeetingNoteContext? {
        guard let note = selectedNote, let transcript, !transcript.segments.isEmpty else { return nil }
        return MeetingNoteContext.around(capturedAtMS: note.capturedAtMS, in: transcript)
    }

    func bind(sessionID: String, snapshot: RawMeetingNotes? = nil, clock: (() -> Int)? = nil) {
        self.sessionID = sessionID
        meetingClock = clock
        selectedNoteID = nil
        draftText = ""
        draftCapturedAtMS = nil
        clearDraftAfterSave = false
        transcript = nil
        saveState = .saved(updatedAt: nil)
        if let snapshot {
            accept(snapshot: snapshot)
        } else {
            self.snapshot = nil
            selectedTemplate = .general
            notifyChanged()
        }
    }

    /// Closing the window must not call this method. The coordinator unbinds
    /// only after the active recording/session has actually ended.
    func unbind() {
        sessionID = nil
        meetingClock = nil
        snapshot = nil
        selectedNoteID = nil
        draftText = ""
        draftCapturedAtMS = nil
        clearDraftAfterSave = false
        selectedTemplate = .general
        saveState = .unbound
        status = .unbound
        transcript = nil
        notifyChanged()
    }

    /// Accept a state snapshot from the sole notes-store owner. Snapshots for a
    /// different session are deliberately ignored so a delayed save cannot
    /// paint another meeting's notes into this window.
    @discardableResult
    func accept(snapshot: RawMeetingNotes) -> Bool {
        guard snapshot.sessionID == sessionID else { return false }
        self.snapshot = snapshot
        selectedTemplate = MeetingNoteTemplate.known(snapshot.template) ?? .general
        saveState = .saved(updatedAt: snapshot.updatedAt)

        if clearDraftAfterSave {
            clearDraftAfterSave = false
            selectedNoteID = nil
            draftText = ""
            draftCapturedAtMS = nil
        } else if let selectedNoteID,
           !snapshot.notes.contains(where: { $0.id == selectedNoteID }) {
            self.selectedNoteID = nil
            draftText = ""
            draftCapturedAtMS = nil
        }
        notifyChanged()
        return true
    }

    func setStatus(_ status: MeetingPadStatus) {
        guard isBound else {
            if self.status != .unbound {
                self.status = .unbound
                notifyChanged()
            }
            return
        }
        guard self.status != status else { return }
        self.status = status
        notifyChanged()
    }

    @discardableResult
    func acceptTranscript(_ transcript: SessionTranscript?, sessionID: String) -> Bool {
        guard sessionID == self.sessionID else { return false }
        guard self.transcript != transcript else { return true }
        self.transcript = transcript
        notifyChanged()
        return true
    }

    func setSaveState(_ state: SaveState) {
        if !isBound {
            switch state {
            case .unbound, .failed: break
            case .waitingForSave, .saved: return
            }
        }
        if case .failed = state { clearDraftAfterSave = false }
        saveState = state
        notifyChanged()
    }

    func selectTemplate(_ template: MeetingNoteTemplate) {
        guard let sessionID else { return }
        selectedTemplate = template
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           selectedNoteID == nil {
            draftText = template.starterText
            draftCapturedAtMS = nil
        }
        saveState = .waitingForSave
        onCommand?(.selectTemplate(sessionID: sessionID, template: template.rawValue))
        notifyChanged()
    }

    func updateDraft(_ text: String) {
        draftText = text
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasContent {
            if selectedNoteID == nil { draftCapturedAtMS = nil }
        } else if selectedNoteID == nil, draftCapturedAtMS == nil, let meetingClock {
            draftCapturedAtMS = max(0, meetingClock())
        }
    }

    func selectNote(id: String) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        selectedNoteID = note.id
        draftText = note.text
        draftCapturedAtMS = nil
        notifyChanged()
    }

    func startNewNote() {
        selectedNoteID = nil
        draftText = ""
        draftCapturedAtMS = nil
        notifyChanged()
    }

    func saveDraft() {
        guard let sessionID else { return }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            saveState = .failed(message: "Write a note before saving.")
            notifyChanged()
            return
        }
        saveState = .waitingForSave
        clearDraftAfterSave = true
        let capturedAtMS = selectedNoteID == nil ? draftCapturedAtMS : nil
        onCommand?(.saveNote(sessionID: sessionID, noteID: selectedNoteID, text: text, capturedAtMS: capturedAtMS))
        notifyChanged()
    }

    func deleteSelectedNote() {
        guard let sessionID, let selectedNoteID else { return }
        saveState = .waitingForSave
        onCommand?(.deleteNote(sessionID: sessionID, noteID: selectedNoteID))
        notifyChanged()
    }

    func requestTimestampMarker() {
        guard let sessionID else { return }
        onCommand?(.requestTimestampMarker(sessionID: sessionID))
    }

    /// The recording coordinator supplies its meeting-relative marker. The
    /// UI accepts display text rather than computing timestamps itself.
    func insertTimestampMarker(_ marker: String) {
        guard !marker.isEmpty else { return }
        let separator = draftText.isEmpty || draftText.hasSuffix("\n") ? "" : "\n"
        draftText += "\(separator)\(marker) "
        if selectedNoteID == nil, draftCapturedAtMS == nil, let meetingClock {
            draftCapturedAtMS = max(0, meetingClock())
        }
        notifyChanged()
    }

    private func notifyChanged() {
        onChange?()
    }
}
