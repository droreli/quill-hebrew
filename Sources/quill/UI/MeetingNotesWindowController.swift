import AppKit

/// A keyboard-first, local-only meeting pad. It has no recording controls or
/// persistence dependency: callers bind a `MeetingNotesViewModel`, feed it
/// lifecycle facts, and handle its commands in their own session layer.
@MainActor
final class MeetingNotesWindowController: NSWindowController, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let viewModel: MeetingNotesViewModel

    var onEnhance: ((MeetingEnhancementAvailability.Action) -> Void)?

    private let templateSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    private let editor: NSTextView
    private let editorScrollView: NSScrollView
    private let noteTable = NSTableView()
    private let noteListScrollView = NSScrollView()
    private let noteListContainer = NSView()
    private let noteListEmptyState = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Add note", target: nil, action: nil)
    private let newNoteButton = NSButton(title: "New", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let markerButton = NSButton(title: "Time marker", target: nil, action: nil)
    private let enhanceButton = NSButton(title: "", target: nil, action: nil)
    private let enhanceGuidance = NSTextField(wrappingLabelWithString: "")

    private let lifecycleDot = NSView()
    private let lifecycleHeadline = NSTextField(labelWithString: "")
    private let lifecycleDetail = NSTextField(wrappingLabelWithString: "")
    private var lifecycleCard: NSView!
    private var elapsedTimer: Timer?

    private var contextCard: NSView!
    private let contextTitle = NSTextField(labelWithString: "")
    private let contextLines = NSStackView()
    private var isApplyingModel = false

    convenience init() {
        self.init(viewModel: MeetingNotesViewModel())
    }

    init(viewModel: MeetingNotesViewModel) {
        self.viewModel = viewModel
        let editorSurface = Self.makeEditorSurface()
        self.editor = editorSurface.editor
        self.editorScrollView = editorSurface.scrollView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Meeting notes"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 480, height: 520)
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
        lifecycleCard = buildLifecycleCard()
        let capture = buildCapture()
        let timeline = buildTimeline()
        contextCard = buildContextCard()
        let footer = buildFooter()
        let stack = NSStackView(views: [header, lifecycleCard, capture, timeline, contextCard, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        for view in [header, lifecycleCard!, capture, timeline, contextCard!, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        editorScrollView.setContentHuggingPriority(.init(1), for: .vertical)
        noteListContainer.setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    private func configureControls() {
        templateSelector.addItems(withTitles: MeetingNoteTemplate.allCases.map(\.title))
        templateSelector.target = self
        templateSelector.action = #selector(templateChanged)
        templateSelector.controlSize = .small
        templateSelector.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
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
        noteListScrollView.setAccessibilityLabel("Saved meeting notes timeline")

        for button in [saveButton, newNoteButton, deleteButton, markerButton, enhanceButton] {
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
        newNoteButton.title = ""
        newNoteButton.image = symbol("square.and.pencil", size: 13)
        newNoteButton.imagePosition = .imageOnly
        newNoteButton.toolTip = "New note"
        newNoteButton.setAccessibilityLabel("Start a new note")

        deleteButton.action = #selector(deleteSelectedNote)
        deleteButton.title = ""
        deleteButton.image = symbol("trash", size: 13)
        deleteButton.imagePosition = .imageOnly
        deleteButton.toolTip = "Delete selected note"
        deleteButton.setAccessibilityLabel("Delete selected note")

        markerButton.action = #selector(addTimestampMarker)
        markerButton.keyEquivalent = "t"
        markerButton.keyEquivalentModifierMask = [.command, .shift]
        markerButton.image = symbol("clock.badge.plus", size: 13)
        markerButton.setAccessibilityLabel("Add meeting time marker")
        markerButton.setAccessibilityHelp("Inserts the current meeting-relative time into the draft. Command Shift T.")

        enhanceButton.action = #selector(enhance)
        enhanceButton.keyEquivalent = "e"
        enhanceButton.keyEquivalentModifierMask = [.command, .shift]
        enhanceButton.controlSize = .large
        enhanceButton.setAccessibilityIdentifier("meetingNotes.enhance")

        enhanceGuidance.font = .systemFont(ofSize: 11)
        enhanceGuidance.textColor = .secondaryLabelColor
        enhanceGuidance.alignment = .natural
        enhanceGuidance.maximumNumberOfLines = 2
        enhanceGuidance.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        enhanceGuidance.setAccessibilityLabel("AI brief availability")

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .natural
        statusLabel.setAccessibilityLabel("Notes save status")

        lifecycleDot.wantsLayer = true
        lifecycleDot.layer?.cornerRadius = 5
        lifecycleDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        lifecycleDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        lifecycleDot.setAccessibilityElement(false)
        lifecycleHeadline.font = .systemFont(ofSize: 13, weight: .semibold)
        lifecycleHeadline.textColor = .labelColor
        lifecycleHeadline.lineBreakMode = .byTruncatingTail
        lifecycleHeadline.alignment = .natural
        lifecycleHeadline.setAccessibilityIdentifier("meetingNotes.lifecycleHeadline")
        lifecycleDetail.font = .systemFont(ofSize: 11)
        lifecycleDetail.textColor = .secondaryLabelColor
        lifecycleDetail.alignment = .natural
        lifecycleDetail.maximumNumberOfLines = 2
        lifecycleDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contextTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        contextTitle.textColor = .labelColor
        contextTitle.alignment = .natural
        contextLines.orientation = .vertical
        contextLines.alignment = .leading
        contextLines.spacing = 4
    }

    /// Use AppKit's native scrollable text-view pair so the document view
    /// follows the scroll viewport as it is laid out. A manually assembled
    /// zero-frame text view remains zero-width when assigned as `documentView`:
    /// it can accept and save text, but TextKit has no line width to draw into.
    private static func makeEditorSurface() -> (scrollView: NSScrollView, editor: NSTextView) {
        let scrollView = NSTextView.scrollableTextView()
        guard let editor = scrollView.documentView as? NSTextView else {
            preconditionFailure("AppKit did not create a text view document")
        }
        return (scrollView, editor)
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
        noteTable.rowHeight = 52
        noteTable.intercellSpacing = NSSize(width: 0, height: 4)
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
        let icon = NSImageView(image: symbol("note.text", size: 16)!)
        icon.contentTintColor = .controlAccentColor
        let title = label("Meeting notes", size: 18, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = stack([icon, title, spacer, templateSelector], orientation: .horizontal, spacing: 8, alignment: .centerY)
        header.setAccessibilityLabel("Meeting notes header")
        return header
    }

    private func buildLifecycleCard() -> NSView {
        let headlineRow = stack([lifecycleDot, lifecycleHeadline], orientation: .horizontal, spacing: 7, alignment: .centerY)
        let body = stack([headlineRow, lifecycleDetail], orientation: .vertical, spacing: 2)
        let card = PadCardView(content: body, insets: NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12))
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("Meeting status")
        return card
    }

    private func buildCapture() -> NSView {
        let editorTitle = label("Capture", size: 12, weight: .semibold)
        let editorHint = label("⌘↩ saves · stamped when you start writing", size: 11, weight: .regular, color: .tertiaryLabelColor)
        editorHint.lineBreakMode = .byTruncatingTail
        let editorHeader = stack([editorTitle, editorHint], orientation: .horizontal, spacing: 8, alignment: .centerY)
        let column = stack([editorHeader, editorScrollView], orientation: .vertical, spacing: 5)
        editorScrollView.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        editorScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        return column
    }

    private func buildTimeline() -> NSView {
        let listTitle = label("Timeline", size: 12, weight: .semibold)
        let column = stack([listTitle, noteListContainer], orientation: .vertical, spacing: 5)
        noteListContainer.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        noteListContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        noteListContainer.heightAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        return column
    }

    private func buildContextCard() -> NSView {
        let icon = NSImageView(image: symbol("text.quote", size: 11)!)
        icon.contentTintColor = .controlAccentColor
        icon.setAccessibilityElement(false)
        let titleRow = stack([icon, contextTitle], orientation: .horizontal, spacing: 6, alignment: .centerY)
        let body = stack([titleRow, contextLines], orientation: .vertical, spacing: 6)
        contextLines.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        let card = PadCardView(content: body, insets: NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12))
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("Transcript context for the selected note")
        return card
    }

    private func buildFooter() -> NSView {
        let privateIcon = NSImageView(image: symbol("lock.fill", size: 10)!)
        privateIcon.contentTintColor = .secondaryLabelColor
        let privateLabel = label("Local only", size: 11, weight: .medium, color: .secondaryLabelColor)
        let privateIndicator = stack([privateIcon, privateLabel], orientation: .horizontal, spacing: 4, alignment: .centerY)
        privateIndicator.setAccessibilityLabel("Private: notes stay local to this meeting")
        privateIndicator.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = stack([newNoteButton, deleteButton, markerButton, saveButton], orientation: .horizontal, spacing: 6, alignment: .centerY)
        let actionRow = stack([privateIndicator, spacer, actions], orientation: .horizontal, spacing: 8, alignment: .centerY)
        actionRow.setAccessibilityLabel("Note actions")

        let enhanceSpacer = NSView()
        enhanceSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let enhanceRow = stack([enhanceGuidance, enhanceSpacer, enhanceButton], orientation: .horizontal, spacing: 8, alignment: .centerY)
        enhanceRow.setAccessibilityLabel("AI brief")

        let footer = stack([separator(), statusLabel, actionRow, enhanceRow], orientation: .vertical, spacing: 7)
        for row in [actionRow, enhanceRow] {
            row.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        }
        return footer
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
        renderLifecycle()
        renderEnhancement()
        rebuildNoteTable()
        renderContext()

        templateSelector.nextKeyView = editor
        editor.nextKeyView = markerButton
        markerButton.nextKeyView = saveButton
        saveButton.nextKeyView = newNoteButton
        newNoteButton.nextKeyView = deleteButton
        deleteButton.nextKeyView = enhanceButton
        enhanceButton.nextKeyView = templateSelector
    }

    private func renderLifecycle() {
        let lifecycle = viewModel.status.lifecycle
        lifecycleHeadline.stringValue = lifecycle.headline(elapsed: elapsedText(for: lifecycle))
        lifecycleDetail.stringValue = lifecycle.detail
        lifecycleDot.layer?.backgroundColor = lifecycleTint(for: lifecycle).cgColor
        lifecycleCard.setAccessibilityValue(lifecycle.accessibilityDescription)
        lifecycleHeadline.setAccessibilityLabel(lifecycle.accessibilityDescription)
        if lifecycle.isRecording {
            if elapsedTimer == nil {
                elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tickElapsed() }
                }
            }
        } else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        }
    }

    private func tickElapsed() {
        let lifecycle = viewModel.status.lifecycle
        guard lifecycle.isRecording else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            return
        }
        lifecycleHeadline.stringValue = lifecycle.headline(elapsed: elapsedText(for: lifecycle))
    }

    private func elapsedText(for lifecycle: MeetingPadLifecycle) -> String? {
        guard case let .recording(startedAt) = lifecycle else { return nil }
        return MeetingNoteContext.clock(Int(max(0, Date().timeIntervalSince(startedAt)) * 1_000))
    }

    private func lifecycleTint(for lifecycle: MeetingPadLifecycle) -> NSColor {
        switch lifecycle {
        case .unbound: .tertiaryLabelColor
        case .recording: .systemRed
        case let .stopped(transcript):
            switch transcript {
            case .afterRecording, .pending, .transcribing: .systemOrange
            case .failed: .systemRed
            case .disabled: .tertiaryLabelColor
            case .ready: .systemGreen
            }
        }
    }

    private func renderEnhancement() {
        let enhancement = viewModel.status.enhancement
        enhanceButton.title = enhancement.buttonTitle
        enhanceButton.isEnabled = enhancement.isEnabled
        enhanceButton.image = symbol(enhanceSymbolName(for: enhancement), size: 13)
        enhanceButton.bezelColor = enhancement.isEnabled ? .controlAccentColor : nil
        enhanceButton.setAccessibilityLabel(enhancement.buttonTitle)
        enhanceButton.setAccessibilityHelp(enhancement.guidance)
        enhanceGuidance.stringValue = enhancement.guidance
        enhanceGuidance.setAccessibilityValue(enhancement.guidance)
    }

    private func enhanceSymbolName(for enhancement: MeetingEnhancementAvailability) -> String {
        switch enhancement {
        case .providerDisabled: "cpu"
        case .briefAvailable: "doc.text"
        default: "sparkles"
        }
    }

    private func renderContext() {
        contextLines.arrangedSubviews.forEach {
            contextLines.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let context = viewModel.selectedNoteContext else {
            contextCard.isHidden = true
            contextCard.setAccessibilityValue("")
            return
        }
        contextCard.isHidden = false
        let anchor = MeetingNoteContext.clock(context.capturedAtMS)
        contextTitle.stringValue = context.isNearestFallback ? "Nearest to \(anchor)" : "Said around \(anchor)"
        for line in context.lines {
            let row = ContextLineView(
                stamp: "\(MeetingNoteContext.clock(line.startMS)) \(speakerTitle(line.speaker))",
                text: line.text
            )
            contextLines.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contextLines.widthAnchor).isActive = true
        }
        let spoken = context.lines.map { "\(speakerTitle($0.speaker)) at \(MeetingNoteContext.clock($0.startMS)): \($0.text)" }
        contextCard.setAccessibilityValue(([contextTitle.stringValue] + spoken).joined(separator: ". "))
    }

    private func speakerTitle(_ speaker: String) -> String {
        switch speaker.lowercased() {
        case "me": "Me"
        case "them": "Them"
        default: speaker
        }
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
            noteTable.scrollRowToVisible(row)
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
            timestamp: MeetingNoteContext.clock(note.capturedAtMS),
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

    @objc private func enhance() {
        let action = viewModel.status.enhancement.action
        guard action != .none else { return }
        onEnhance?(action)
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
            content.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            timestampLabel.widthAnchor.constraint(equalToConstant: 44),
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

/// One transcript line: a fixed left-to-right stamp column and a wrapping
/// natural-direction text column, so Hebrew lines read right-to-left while
/// the stamp stays put.
private final class ContextLineView: NSView {
    init(stamp: String, text: String) {
        super.init(frame: .zero)
        let stampLabel = NSTextField(labelWithString: stamp)
        stampLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        stampLabel.textColor = .secondaryLabelColor
        stampLabel.alignment = .left
        stampLabel.baseWritingDirection = .leftToRight
        stampLabel.lineBreakMode = .byTruncatingTail
        let textLabel = NSTextField(wrappingLabelWithString: text)
        textLabel.font = .systemFont(ofSize: 12)
        textLabel.textColor = .labelColor
        textLabel.alignment = .natural
        textLabel.baseWritingDirection = .natural
        textLabel.maximumNumberOfLines = 3
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [stampLabel, textLabel])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            stampLabel.widthAnchor.constraint(equalToConstant: 76),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(stamp)
        setAccessibilityValue(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// Quiet elevated surface using semantic colors, refreshed on appearance
/// changes so Dark Mode never keeps a stale light-mode layer color.
private final class PadCardView: NSView {
    init(content: NSView, insets: NSEdgeInsets) {
        super.init(frame: .zero)
        wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
