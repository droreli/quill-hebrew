import AppKit

/// A keyboard-first, local-only notes surface. It has no recording controls or
/// persistence dependency: callers bind a `MeetingNotesViewModel` and handle
/// its commands in their own session/persistence layer.
@MainActor
final class MeetingNotesWindowController: NSWindowController, NSTextViewDelegate {
    let viewModel: MeetingNotesViewModel

    private let templateSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    private let editor = NSTextView(frame: .zero)
    private let editorScrollView = NSScrollView()
    private let noteList = NSStackView()
    private let noteListScrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Add note", target: nil, action: nil)
    private let newNoteButton = NSButton(title: "New", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let markerButton = NSButton(title: "Add time marker", target: nil, action: nil)
    private var isApplyingModel = false

    convenience init() {
        self.init(viewModel: MeetingNotesViewModel())
    }

    init(viewModel: MeetingNotesViewModel) {
        self.viewModel = viewModel
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Meeting notes"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 620, height: 480)
        window.isReleasedWhenClosed = false
        let autosaveName = "QuillMeetingNotesWindow"
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
        super.init(window: window)
        build()
        viewModel.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(editor)
    }

    private func build() {
        guard let window else { return }
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        configureControls()
        let header = buildHeader()
        let body = buildBody()
        let footer = buildFooter()
        let stack = NSStackView(views: [header, body, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
    }

    private func configureControls() {
        templateSelector.addItems(withTitles: MeetingNoteTemplate.allCases.map(\.title))
        templateSelector.target = self
        templateSelector.action = #selector(templateChanged)
        templateSelector.setAccessibilityLabel("Meeting note template")
        templateSelector.setAccessibilityHelp("Choose a starting structure for a new note.")

        editor.isRichText = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.insertionPointColor = .controlAccentColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.baseWritingDirection = .natural
        editor.delegate = self
        editor.setAccessibilityLabel("Meeting note editor")
        editor.setAccessibilityHelp("Write a note using headings and bullets. Command Return saves it.")
        editorScrollView.hasVerticalScroller = true
        editorScrollView.autohidesScrollers = true
        editorScrollView.borderType = .bezelBorder
        editorScrollView.documentView = editor

        noteList.orientation = .vertical
        noteList.alignment = .leading
        noteList.spacing = 8
        noteList.translatesAutoresizingMaskIntoConstraints = false
        let noteListContent = NSView()
        noteListContent.translatesAutoresizingMaskIntoConstraints = false
        noteListContent.addSubview(noteList)
        NSLayoutConstraint.activate([
            noteList.leadingAnchor.constraint(equalTo: noteListContent.leadingAnchor),
            noteList.trailingAnchor.constraint(equalTo: noteListContent.trailingAnchor),
            noteList.topAnchor.constraint(equalTo: noteListContent.topAnchor),
            noteList.bottomAnchor.constraint(equalTo: noteListContent.bottomAnchor),
            noteList.widthAnchor.constraint(equalTo: noteListContent.widthAnchor),
        ])
        noteListScrollView.hasVerticalScroller = true
        noteListScrollView.autohidesScrollers = true
        noteListScrollView.borderType = .bezelBorder
        noteListScrollView.documentView = noteListContent
        noteListScrollView.setAccessibilityLabel("Saved meeting notes")

        for button in [saveButton, newNoteButton, deleteButton, markerButton] {
            button.target = self
            button.bezelStyle = .rounded
            button.imagePosition = .imageLeading
        }
        saveButton.action = #selector(saveDraft)
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.image = symbol("plus.circle.fill", size: 13)
        saveButton.setAccessibilityLabel("Save note")

        newNoteButton.action = #selector(newNote)
        newNoteButton.image = symbol("square.and.pencil", size: 13)
        newNoteButton.setAccessibilityLabel("Start a new note")

        deleteButton.action = #selector(deleteSelectedNote)
        deleteButton.image = symbol("trash", size: 13)
        deleteButton.setAccessibilityLabel("Delete selected note")

        markerButton.action = #selector(addTimestampMarker)
        markerButton.image = symbol("clock.badge.plus", size: 13)
        markerButton.setAccessibilityLabel("Add meeting time marker")
        markerButton.setAccessibilityHelp("Requests a meeting-relative timestamp from Quill and inserts it into the draft.")

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .natural
        statusLabel.setAccessibilityLabel("Notes save status")
    }

    private func buildHeader() -> NSView {
        let icon = NSImageView(image: symbol("note.text", size: 18)!)
        icon.contentTintColor = .controlAccentColor
        let title = label("Meeting notes", size: 22, weight: .semibold)
        let subtitle = label("Private notes for this meeting", size: 12, weight: .medium, color: .secondaryLabelColor)
        let copy = stack([title, subtitle], orientation: .vertical, spacing: 1)
        let templateLabel = label("Template", size: 11, weight: .semibold, color: .secondaryLabelColor)
        let picker = stack([templateLabel, templateSelector], orientation: .vertical, spacing: 4)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack([icon, copy, spacer, picker], orientation: .horizontal, spacing: 9, alignment: .centerY)
    }

    private func buildBody() -> NSView {
        let editorTitle = label("Capture a thought", size: 13, weight: .semibold)
        let editorHint = label("⌘↩ saves · headings and bullets work well", size: 11, weight: .regular, color: .tertiaryLabelColor)
        let editorHeader = stack([editorTitle, editorHint], orientation: .horizontal, spacing: 8, alignment: .centerY)
        let editorColumn = stack([editorHeader, editorScrollView], orientation: .vertical, spacing: 7)
        let listTitle = label("Saved notes", size: 13, weight: .semibold)
        let listColumn = stack([listTitle, noteListScrollView], orientation: .vertical, spacing: 7)
        let result = stack([editorColumn, listColumn], orientation: .horizontal, spacing: 16, alignment: .top)
        result.distribution = .fillEqually
        editorScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        noteListScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        return result
    }

    private func buildFooter() -> NSView {
        let privateIcon = NSImageView(image: symbol("lock.fill", size: 11)!)
        privateIcon.contentTintColor = .secondaryLabelColor
        let privateLabel = label("Stored locally in this meeting only", size: 11, weight: .medium, color: .secondaryLabelColor)
        let privateIndicator = stack([privateIcon, privateLabel], orientation: .horizontal, spacing: 5, alignment: .centerY)
        privateIndicator.setAccessibilityLabel("Private: notes stay local to this meeting")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = stack([newNoteButton, deleteButton, markerButton, saveButton], orientation: .horizontal, spacing: 7, alignment: .centerY)
        let footer = stack([privateIndicator, spacer, actions], orientation: .horizontal, spacing: 9, alignment: .centerY)
        footer.setAccessibilityLabel("Note actions")
        return stack([separator(), statusLabel, footer], orientation: .vertical, spacing: 8)
    }

    private func render() {
        isApplyingModel = true
        defer { isApplyingModel = false }
        let bound = viewModel.isBound
        let templateIndex = MeetingNoteTemplate.allCases.firstIndex(of: viewModel.selectedTemplate) ?? 0
        templateSelector.selectItem(at: templateIndex)
        templateSelector.isEnabled = bound
        editor.isEditable = bound
        editor.textColor = bound ? .labelColor : .secondaryLabelColor
        if editor.string != viewModel.draftText { editor.string = viewModel.draftText }
        editor.setAccessibilityValue(viewModel.draftText)
        saveButton.title = viewModel.hasSelectedNote ? "Save changes" : "Add note"
        saveButton.isEnabled = bound
        newNoteButton.isEnabled = bound && viewModel.hasSelectedNote
        deleteButton.isEnabled = bound && viewModel.hasSelectedNote
        markerButton.isEnabled = bound
        statusLabel.stringValue = statusText(for: viewModel.saveState)
        statusLabel.textColor = statusColor(for: viewModel.saveState)
        statusLabel.setAccessibilityValue(viewModel.saveState.accessibilityDescription)
        rebuildNoteList()

        templateSelector.nextKeyView = editor
        editor.nextKeyView = markerButton
        markerButton.nextKeyView = saveButton
        saveButton.nextKeyView = newNoteButton
        newNoteButton.nextKeyView = deleteButton
    }

    private func rebuildNoteList() {
        noteList.arrangedSubviews.forEach {
            noteList.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard viewModel.isBound else {
            noteList.addArrangedSubview(emptyState("Bind a meeting to start taking notes."))
            return
        }
        guard !viewModel.notes.isEmpty else {
            noteList.addArrangedSubview(emptyState("No saved notes yet. Capture the first thing worth remembering."))
            return
        }
        for note in viewModel.notes.reversed() {
            let row = noteRow(note)
            noteList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: noteList.widthAnchor).isActive = true
        }
    }

    private func noteRow(_ note: RawMeetingNotes.Note) -> NSButton {
        let title = timestampText(note.capturedAtMS)
        let preview = note.text.replacingOccurrences(of: "\n", with: " ")
        let button = NSButton(title: "\(title)  \(preview)", target: self, action: #selector(noteSelected(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(note.id)
        button.tag = 0
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .recessed
        button.alignment = .natural
        button.lineBreakMode = .byTruncatingTail
        button.image = symbol("clock", size: 11)
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel("Note at \(title)")
        button.setAccessibilityValue(note.text)
        button.setAccessibilityHelp("Edit this note in the note editor.")
        button.state = note.id == viewModel.selectedNoteID ? .on : .off
        return button
    }

    private func emptyState(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .natural
        label.setAccessibilityLabel(text)
        return label
    }

    private func statusText(for state: MeetingNotesViewModel.SaveState) -> String {
        switch state {
        case .unbound: "No active meeting — notes are waiting for a session."
        case .waitingForSave: "Saving locally…"
        case let .saved(updatedAt): updatedAt.map { "Saved locally · \($0)" } ?? "Ready to save locally"
        case let .failed(message): "Couldn’t save: \(message)"
        }
    }

    private func statusColor(for state: MeetingNotesViewModel.SaveState) -> NSColor {
        switch state {
        case .failed: .systemRed
        case .waitingForSave: .secondaryLabelColor
        case .saved: .systemGreen
        case .unbound: .secondaryLabelColor
        }
    }

    private func timestampText(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .natural
        return label
    }

    private func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.alignment = alignment
        stack.spacing = spacing
        return stack
    }

    private func separator() -> NSView {
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingModel else { return }
        viewModel.updateDraft(editor.string)
    }

    @objc private func templateChanged() {
        guard let template = MeetingNoteTemplate.allCases[safe: templateSelector.indexOfSelectedItem] else { return }
        viewModel.selectTemplate(template)
    }

    @objc private func saveDraft() { viewModel.saveDraft() }

    @objc private func newNote() {
        viewModel.startNewNote()
        window?.makeFirstResponder(editor)
    }

    @objc private func deleteSelectedNote() { viewModel.deleteSelectedNote() }

    @objc private func addTimestampMarker() {
        viewModel.requestTimestampMarker()
        window?.makeFirstResponder(editor)
    }

    @objc private func noteSelected(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        viewModel.selectNote(id: id)
        window?.makeFirstResponder(editor)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
