import AppKit

/// Native recordings library. The selected row is the only source for its
/// actions; callers receive the exact directory, never an inferred "latest".
@MainActor
final class MeetingLibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelectSession: ((URL) -> Void)?
    var onOpenNotes: ((URL) -> Void)?
    var onOpenBrief: ((URL) -> Void)?
    var onRevealSession: ((URL) -> Void)?
    var onOpenListeningCopy: ((URL) -> Void)?

    private let root: URL
    private var snapshot = MeetingLibrarySessions.Snapshot(sessions: [], errorMessage: nil)
    private var selectedDirectory: URL?
    private var isApplyingSelection = false
    private var isRecording = false
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "Select a recording")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let transcriptLabel = NSTextField(wrappingLabelWithString: "")
    private let audioLabel = NSTextField(wrappingLabelWithString: "")
    private let briefLabel = NSTextField(wrappingLabelWithString: "")
    private let revealButton = NSButton(title: "Reveal session", target: nil, action: nil)
    private let listeningButton = NSButton(title: "Open listening copy", target: nil, action: nil)
    private let notesButton = NSButton(title: "Open notes", target: nil, action: nil)
    private let briefButton = NSButton(title: "Open meeting brief", target: nil, action: nil)

    init(root: URL) {
        self.root = root
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Meeting library"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("QuillMeetingLibraryWindow") { window.center() }
        window.setFrameAutosaveName("QuillMeetingLibraryWindow")
        super.init(window: window)
        build()
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func show(selected: URL?) {
        refresh(selected: selected)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func updateRecordingState(_ isRecording: Bool) {
        self.isRecording = isRecording
        renderSelection()
    }

    func refresh(selected: URL? = nil) {
        snapshot = MeetingLibrarySessions.snapshot(in: root)
        let desired = selected ?? selectedDirectory
        selectedDirectory = desired.flatMap { desired in
            snapshot.sessions.first(where: { $0.directory.standardizedFileURL == desired.standardizedFileURL })?.directory
        } ?? (desired == nil ? snapshot.sessions.first?.directory : nil)
        isApplyingSelection = true
        table.reloadData()
        if let selectedDirectory,
           let row = snapshot.sessions.firstIndex(where: { $0.directory.standardizedFileURL == selectedDirectory.standardizedFileURL }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        isApplyingSelection = false
        renderSelection()
    }

    private func build() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = content

        let headerTitle = NSTextField(labelWithString: "Meeting library")
        headerTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        let headerDetail = NSTextField(wrappingLabelWithString: "Choose a completed recording to inspect its local transcript, source tracks, listening copy, notes, or brief.")
        headerDetail.font = .systemFont(ofSize: 12)
        headerDetail.textColor = .secondaryLabelColor
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshButton.image = symbol("arrow.clockwise")
        refreshButton.imagePosition = .imageLeading
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = stack([stack([headerTitle, headerDetail], vertical: true), spacer, refreshButton], vertical: false)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("meeting"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 48
        table.usesAlternatingRowBackgroundColors = false
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.borderType = .bezelBorder
        list.translatesAutoresizingMaskIntoConstraints = false
        table.setAccessibilityLabel("Completed recordings")

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(list)
        listContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor), list.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            list.topAnchor.constraint(equalTo: listContainer.topAnchor), list.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 18), emptyLabel.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -18),
            emptyLabel.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
        ])

        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        for label in [detailLabel, transcriptLabel, audioLabel, briefLabel] {
            label.font = .systemFont(ofSize: 12)
            label.maximumNumberOfLines = 0
        }
        detailLabel.textColor = .secondaryLabelColor
        transcriptLabel.textColor = .labelColor
        audioLabel.textColor = .labelColor
        briefLabel.textColor = .secondaryLabelColor
        for button in [revealButton, listeningButton, notesButton, briefButton] {
            button.target = self
            button.bezelStyle = .rounded
            button.imagePosition = .imageLeading
        }
        revealButton.action = #selector(reveal)
        revealButton.image = symbol("folder")
        listeningButton.action = #selector(openListeningCopy)
        listeningButton.image = symbol("play.circle")
        notesButton.action = #selector(openNotes)
        notesButton.image = symbol("note.text")
        briefButton.action = #selector(openBrief)
        briefButton.image = symbol("sparkles")
        briefButton.controlSize = .large
        let actions = stack([revealButton, listeningButton, notesButton, briefButton], vertical: false)
        let detailStack = stack([titleLabel, detailLabel, separator(), transcriptLabel, audioLabel, briefLabel, spacerView(), actions], vertical: true)
        detailStack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        detailStack.setAccessibilityLabel("Selected meeting details")

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(listContainer)
        split.addArrangedSubview(detailStack)
        split.translatesAutoresizingMaskIntoConstraints = false
        listContainer.widthAnchor.constraint(equalToConstant: 300).isActive = true
        content.addSubview(header)
        content.addSubview(split)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), header.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), split.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18), split.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
    }

    private func renderSelection() {
        let noSessionsMessage = snapshot.errorMessage ?? "No completed recordings yet. Stop a recording to add it here; raw audio is never created or moved by this library."
        emptyLabel.stringValue = snapshot.sessions.isEmpty ? noSessionsMessage : ""
        emptyLabel.isHidden = !snapshot.sessions.isEmpty
        guard let session = selectedSession else {
            titleLabel.stringValue = snapshot.errorMessage == nil ? "Select a recording" : "Library unavailable"
            detailLabel.stringValue = noSessionsMessage
            transcriptLabel.stringValue = ""
            audioLabel.stringValue = ""
            briefLabel.stringValue = ""
            [revealButton, listeningButton, notesButton, briefButton].forEach { $0.isEnabled = false }
            return
        }
        titleLabel.stringValue = session.title
        detailLabel.stringValue = [session.startedAt.map(displayDate), session.durationSeconds.map(displayDuration)].compactMap { $0 }.joined(separator: " · ")
        transcriptLabel.stringValue = session.transcript.summary
        audioLabel.stringValue = "\(session.audio.sourceSummary). \(session.audio.listeningCopyAvailable ? "Mixed listening copy available." : "No mixed listening copy was saved.")"
        briefLabel.stringValue = session.hasBrief ? "A generated brief exists. Regenerate only from this selected session." : "No generated brief yet."
        revealButton.isEnabled = true
        notesButton.isEnabled = !isRecording
        listeningButton.isEnabled = session.audio.listeningCopyAvailable
        briefButton.isEnabled = session.transcript.canBrief && !isRecording
        briefButton.title = session.hasBrief ? "Open or regenerate brief" : "Open meeting brief"
        if isRecording {
            briefLabel.stringValue = "Finish the active recording before opening notes or a brief for another session."
            briefButton.toolTip = "Disabled while recording so the selected session cannot be confused with the live one."
            notesButton.toolTip = "Disabled while recording so the selected session cannot be confused with the live one."
        } else {
            briefButton.toolTip = session.transcript.canBrief ? "Uses only this selected session’s canonical transcript and notes." : "A canonical transcript is required before a brief can open."
            notesButton.toolTip = nil
        }
        titleLabel.setAccessibilityValue(session.directory.path)
    }

    private var selectedSession: MeetingLibrarySessions.Session? {
        snapshot.sessions.first { $0.directory.standardizedFileURL == selectedDirectory?.standardizedFileURL }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { snapshot.sessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard snapshot.sessions.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("meeting-row")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
        view.identifier = identifier
        let session = snapshot.sessions[row]
        let field = view.textField ?? NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.lineBreakMode = .byTruncatingMiddle
        field.stringValue = session.title
        if view.textField == nil {
            field.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(field)
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10), field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10), field.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            view.textField = field
        }
        view.setAccessibilityLabel(session.title)
        view.setAccessibilityValue(session.transcript.summary)
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        let row = table.selectedRow
        guard snapshot.sessions.indices.contains(row) else { return }
        selectedDirectory = snapshot.sessions[row].directory
        renderSelection()
        if let selectedDirectory { onSelectSession?(selectedDirectory) }
    }

    @objc private func refreshClicked() { refresh(selected: selectedDirectory) }
    @objc private func reveal() { if let selectedDirectory { onRevealSession?(selectedDirectory) } }
    @objc private func openListeningCopy() { selectedDirectory.map { onOpenListeningCopy?($0.appendingPathComponent("mixed.m4a")) } }
    @objc private func openNotes() { if let selectedDirectory { onOpenNotes?(selectedDirectory) } }
    @objc private func openBrief() { if let selectedDirectory { onOpenBrief?(selectedDirectory) } }

    private func stack(_ views: [NSView], vertical: Bool) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = 10
        return stack
    }
    private func separator() -> NSView { let view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = NSColor.separatorColor.cgColor; view.heightAnchor.constraint(equalToConstant: 1).isActive = true; return view }
    private func spacerView() -> NSView { let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .vertical); return view }
    private func symbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) }
    private func displayDate(_ date: Date) -> String { let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; return formatter.string(from: date) }
    private func displayDuration(_ seconds: Int) -> String { let minutes = seconds / 60; let remainder = seconds % 60; return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s" }
}
