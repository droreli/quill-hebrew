import AppKit

/// A keyboard-first, local-only notes surface. It has no recording controls or
/// persistence dependency: callers bind a `MeetingNotesViewModel` and handle
/// its commands in their own session/persistence layer.
@MainActor
final class MeetingNotesWindowController: NSWindowController, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let viewModel: MeetingNotesViewModel

    private let templateSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    private let editor: NSTextView
    private let editorScrollView = NSScrollView()
    private let noteTable = NSTableView()
    private let noteListScrollView = NSScrollView()
    private let noteListContainer = NSView()
    private let noteListEmptyState = NSTextField(wrappingLabelWithString: "")
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
        self.editor = Self.makeEditor()
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

        configureEditor()
        editor.setAccessibilityLabel("Meeting note editor")
        editor.setAccessibilityHelp("Write a note using headings and bullets. Command Return saves it.")
        editorScrollView.hasVerticalScroller = true
        editorScrollView.autohidesScrollers = true
        editorScrollView.borderType = .bezelBorder
        editorScrollView.drawsBackground = true
        editorScrollView.backgroundColor = .textBackgroundColor
        editorScrollView.documentView = editor
        configureNoteTable()
        noteListContainer.translatesAutoresizingMaskIntoConstraints = false
        noteListContainer.addSubview(noteListScrollView)
        noteListContainer.addSubview(noteListEmptyState)
        noteListScrollView.translatesAutoresizingMaskIntoConstraints = false
        noteListEmptyState.translatesAutoresizingMaskIntoConstraints = false
        noteListEmptyState.font = .systemFont(ofSize: 12)
        noteListEmptyState.textColor = .secondaryLabelColor
        noteListEmptyState.alignment = .center
        NSLayoutConstraint.activate([
            noteListScrollView.leadingAnchor.constraint(equalTo: noteListContainer.leadingAnchor),
            noteListScrollView.trailingAnchor.constraint(equalTo: noteListContainer.trailingAnchor),
            noteListScrollView.topAnchor.constraint(equalTo: noteListContainer.topAnchor),
            noteListScrollView.bottomAnchor.constraint(equalTo: noteListContainer.bottomAnchor),
            noteListEmptyState.leadingAnchor.constraint(equalTo: noteListContainer.leadingAnchor, constant: 16),
            noteListEmptyState.trailingAnchor.constraint(equalTo: noteListContainer.trailingAnchor, constant: -16),
            noteListEmptyState.centerYAnchor.constraint(equalTo: noteListContainer.centerYAnchor),
        ])
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

    /// Build the editor with a normal explicit TextKit stack. The previous
    /// subclass rewrote its storage and typing attributes during every edit;
    /// that conflicts with AppKit's complex-script composition path. Keeping
    /// the input manager in charge of its runs is the native rendering route.
    private static func makeEditor() -> NSTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        return NSTextView(frame: .zero, textContainer: container)
    }

    private func configureEditor() {
        let font = NSFont.systemFont(ofSize: 15)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .natural
        paragraph.baseWritingDirection = .natural
        paragraph.lineBreakMode = .byWordWrapping

        editor.isRichText = false
        // Plain NSTextView stores component-based foreground colors in its
        // model. Input managers can insert concrete black even while the view
        // is drawing in Dark Mode (notably when Quill starts from launchd).
        // Let AppKit map those model colors to contrasting display colors.
        editor.usesAdaptiveColorMappingForDarkAppearance = true
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = font
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.drawsBackground = true
        editor.insertionPointColor = .controlAccentColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.baseWritingDirection = .natural
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        editor.delegate = self
        editor.setAccessibilityLabel("Meeting note editor")
        editor.setAccessibilityHelp("Write a note using headings and bullets. Command Return saves it.")
    }

    private func configureNoteTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("saved-note"))
        column.resizingMask = .autoresizingMask
        noteTable.addTableColumn(column)
        noteTable.headerView = nil
        noteTable.delegate = self
        noteTable.dataSource = self
        noteTable.rowHeight = 72
        noteTable.intercellSpacing = NSSize(width: 0, height: 6)
        noteTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        noteTable.selectionHighlightStyle = .regular
        noteTable.usesAlternatingRowBackgroundColors = false
        noteTable.backgroundColor = .clear
        noteTable.focusRingType = .none

        noteListScrollView.hasVerticalScroller = true
        noteListScrollView.autohidesScrollers = true
        noteListScrollView.borderType = .bezelBorder
        noteListScrollView.drawsBackground = true
        noteListScrollView.backgroundColor = .controlBackgroundColor
        noteListScrollView.documentView = noteTable
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
        let listColumn = stack([listTitle, noteListContainer], orientation: .vertical, spacing: 7)
        let result = stack([editorColumn, listColumn], orientation: .horizontal, spacing: 16, alignment: .top)
        result.distribution = .fillEqually
        editorScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        noteListContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
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
        if editor.string != viewModel.draftText { editor.string = viewModel.draftText }
        editor.setAccessibilityValue(viewModel.draftText)
        saveButton.title = viewModel.hasSelectedNote ? "Update note" : "Save note"
        saveButton.isEnabled = bound
        newNoteButton.isEnabled = bound && viewModel.hasSelectedNote
        deleteButton.isEnabled = bound && viewModel.hasSelectedNote
        markerButton.isEnabled = bound
        statusLabel.stringValue = statusText(for: viewModel.saveState)
        statusLabel.textColor = statusColor(for: viewModel.saveState)
        statusLabel.setAccessibilityValue(viewModel.saveState.accessibilityDescription)
        rebuildNoteTable()

        templateSelector.nextKeyView = editor
        editor.nextKeyView = markerButton
        markerButton.nextKeyView = saveButton
        saveButton.nextKeyView = newNoteButton
        newNoteButton.nextKeyView = deleteButton
    }

    private func rebuildNoteTable() {
        let notes = displayedNotes
        noteListEmptyState.stringValue = !viewModel.isBound
            ? "Bind a meeting to start taking notes."
            : "No saved notes yet. Capture the first thing worth remembering."
        noteListEmptyState.isHidden = !notes.isEmpty
        noteTable.reloadData()
        // Programmatic table columns start with a small intrinsic width. Make
        // the single notes column consume the clip view immediately, including
        // its first live population before the next resize pass.
        noteTable.sizeLastColumnToFit()
        if let id = viewModel.selectedNoteID,
           let row = notes.firstIndex(where: { $0.id == id }) {
            noteTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            noteTable.deselectAll(nil)
        }
    }

    private var displayedNotes: [RawMeetingNotes.Note] { viewModel.notes.reversed() }

    private func notePreview(_ text: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "Empty note" }
        let preview = lines.prefix(2).joined(separator: "  ·  ")
        return lines.count > 2 ? "\(preview)…" : preview
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
        case let .saved(updatedAt): updatedAt.map { "Saved locally · \(displayTime($0))" } ?? "Ready to save locally"
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

    private func displayTime(_ isoTimestamp: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: isoTimestamp) else { return isoTimestamp }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
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

    func numberOfRows(in tableView: NSTableView) -> Int { displayedNotes.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard displayedNotes.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("saved-note-cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? MeetingNoteTableCellView)
            ?? MeetingNoteTableCellView(frame: .zero)
        cell.identifier = identifier
        let note = displayedNotes[row]
        cell.configure(
            timestamp: timestampText(note.capturedAtMS),
            preview: notePreview(note.text),
            accessibilityText: note.text
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModel else { return }
        let row = noteTable.selectedRow
        guard displayedNotes.indices.contains(row) else { return }
        viewModel.selectNote(id: displayedNotes[row].id)
        window?.makeFirstResponder(editor)
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

}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A real table cell, rather than a button placed in a stack document view.
/// `NSTableView` owns the row and column geometry, so the preview always has
/// the full readable width of the scroll view instead of shrinking to its
/// intrinsic first glyph width.
private final class MeetingNoteTableCellView: NSTableCellView {
    private let timestampLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        timestampLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timestampLabel.textColor = .secondaryLabelColor
        timestampLabel.alignment = .left
        timestampLabel.baseWritingDirection = .leftToRight
        previewLabel.font = .systemFont(ofSize: 13)
        previewLabel.textColor = .labelColor
        previewLabel.alignment = .natural
        previewLabel.baseWritingDirection = .natural
        previewLabel.maximumNumberOfLines = 2
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = previewLabel

        let content = NSStackView(views: [timestampLabel, previewLabel])
        content.orientation = .horizontal
        content.alignment = .top
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            timestampLabel.widthAnchor.constraint(equalToConstant: 38),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(timestamp: String, preview: String, accessibilityText: String) {
        timestampLabel.stringValue = timestamp
        previewLabel.stringValue = preview
        setAccessibilityLabel("Note at \(timestamp)")
        setAccessibilityValue(accessibilityText)
        setAccessibilityHelp("Select this note to edit it in the note editor.")
    }
}
