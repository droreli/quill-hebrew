import AppKit

/// Native, read-only presentation for a local meeting brief. The coordinator
/// supplies state and owns all actions; this window never edits inputs or
/// reaches into transcript/audio/artifact files itself.
@MainActor
final class MeetingBriefWindowController: NSWindowController {
    var onRegenerate: (() -> Void)?
    var onCancel: (() -> Void)?
    var onReveal: (() -> Void)?
    var onShowEvidence: (([EvidenceReference]) -> Void)?

    let viewModel: MeetingBriefViewModel

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal session", target: nil, action: nil)

    init(viewModel: MeetingBriefViewModel) {
        self.viewModel = viewModel
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Meeting Brief"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 600, height: 520)
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("QuillMeetingBriefWindow") {
            window.center()
        }
        window.setFrameAutosaveName("QuillMeetingBriefWindow")
        super.init(window: window)
        buildWindow()
        viewModel.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = content

        let header = makeHeader()
        let footer = makeFooter()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 26, right: 24)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentStack

        content.addSubview(header)
        content.addSubview(scrollView)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            contentStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    private func makeHeader() -> NSView {
        let title = text("Meeting brief", size: 24, weight: .semibold)
        title.setAccessibilityLabel("Meeting brief")
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityRole(.staticText)
        let copy = vertical([title, statusLabel], spacing: 3)
        let icon = iconTile("sparkles", tint: .controlAccentColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = horizontal([icon, copy, spacer], spacing: 12, alignment: .centerY)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setAccessibilityLabel("Meeting brief status")
        return header
    }

    private func makeFooter() -> NSView {
        primaryButton.target = self
        primaryButton.action = #selector(primaryAction)
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.imagePosition = .imageLeading
        primaryButton.setAccessibilityIdentifier("meetingBrief.primaryAction")

        revealButton.target = self
        revealButton.action = #selector(revealSession)
        revealButton.bezelStyle = .rounded
        revealButton.image = symbol("folder", size: 13, weight: .medium)
        revealButton.imagePosition = .imageLeading
        revealButton.setAccessibilityLabel("Reveal meeting session in Finder")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = horizontal([revealButton, spacer, primaryButton], spacing: 10, alignment: .centerY)
        footer.translatesAutoresizingMaskIntoConstraints = false
        return footer
    }

    private func render() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        statusLabel.stringValue = viewModel.state.title
        statusLabel.setAccessibilityLabel(viewModel.state.accessibilityDescription)
        revealButton.isEnabled = viewModel.sessionDirectory != nil
        configurePrimaryButton(for: viewModel.state)

        switch viewModel.state {
        case .missing:
            add(stateCard(
                symbolName: "doc.text.magnifyingglass",
                title: "No generated brief yet",
                detail: "When a completed transcript is available, generate a local meeting brief. Your source notes remain separate and unchanged."
            ))
        case let .processing(message):
            add(stateCard(
                symbolName: "cpu",
                title: "Generating on this Mac",
                detail: message,
                progress: true
            ))
        case let .failed(message):
            add(stateCard(
                symbolName: "exclamationmark.triangle",
                title: "The brief could not be generated",
                detail: message,
                tone: .systemOrange
            ))
        case .stale:
            add(stateCard(
                symbolName: "arrow.triangle.2.circlepath",
                title: "This brief uses older inputs",
                detail: "The current notes or transcript no longer match the source revision recorded below. Regenerate to create a current brief."
            ))
        case let .ready(brief):
            if brief.inputs.transcriptSegmentCount == 0 {
                add(stateCard(
                    symbolName: "waveform.slash",
                    title: "No speech was transcribed",
                    detail: "LM Studio was not contacted because this recording produced no transcript segments. Check the selected microphone or its input level, then record again before generating a brief.",
                    tone: .systemOrange
                ))
            }
        }

        add(rawNotesCard())
        if let brief = viewModel.state.brief {
            add(briefCard(brief))
        }
    }

    private func configurePrimaryButton(for state: MeetingBriefViewModel.State) {
        primaryButton.isEnabled = true
        switch state {
        case .processing:
            primaryButton.title = "Cancel generation"
            primaryButton.image = symbol("xmark", size: 13, weight: .semibold)
            primaryButton.bezelColor = .systemRed
            primaryButton.setAccessibilityLabel("Cancel meeting brief generation")
        case .missing:
            primaryButton.title = "Generate meeting brief"
            primaryButton.image = symbol("sparkles", size: 13, weight: .semibold)
            primaryButton.bezelColor = .controlAccentColor
            primaryButton.setAccessibilityLabel("Generate a local meeting brief")
        case .failed:
            primaryButton.title = "Try again"
            primaryButton.image = symbol("arrow.clockwise", size: 13, weight: .semibold)
            primaryButton.bezelColor = .controlAccentColor
            primaryButton.setAccessibilityLabel("Try generating the meeting brief again")
        case .stale:
            primaryButton.title = "Regenerate brief"
            primaryButton.image = symbol("arrow.triangle.2.circlepath", size: 13, weight: .semibold)
            primaryButton.bezelColor = .controlAccentColor
            primaryButton.setAccessibilityLabel("Regenerate brief from the current source inputs")
        case let .ready(brief) where brief.inputs.transcriptSegmentCount == 0:
            primaryButton.title = "No transcript to summarize"
            primaryButton.image = symbol("waveform.slash", size: 13, weight: .semibold)
            primaryButton.bezelColor = .systemOrange
            primaryButton.isEnabled = false
            primaryButton.setAccessibilityLabel("No transcript is available to summarize")
        case .ready:
            primaryButton.title = "Regenerate brief"
            primaryButton.image = symbol("arrow.triangle.2.circlepath", size: 13, weight: .semibold)
            primaryButton.bezelColor = .controlAccentColor
            primaryButton.setAccessibilityLabel("Generate a new brief from the current source inputs")
        }
    }

    private func rawNotesCard() -> NSView {
        var rows: [NSView] = []
        if let rawNotes = viewModel.rawNotes, !rawNotes.notes.isEmpty {
            let metadata = "User-owned notes · revision \(rawNotes.revision) · updated \(formattedDate(rawNotes.updatedAt))"
            rows.append(text(metadata, size: 11, weight: .medium, color: .secondaryLabelColor))
            for note in rawNotes.notes {
                let timestamp = "\(formattedTimestamp(note.capturedAtMS)) · User note"
                let heading = text(timestamp, size: 11, weight: .semibold, color: .secondaryLabelColor)
                let content = wrappingText(note.text, size: 13, color: .labelColor)
                let row = vertical([heading, content], spacing: 3)
                row.setAccessibilityLabel("User note at \(formattedTimestamp(note.capturedAtMS))")
                rows.append(row)
            }
        } else {
            rows.append(wrappingText("No raw notes were captured for this session.", size: 13, color: .secondaryLabelColor))
        }
        return card(
            symbolName: "note.text",
            title: "Your raw notes",
            subtitle: "Read-only source notes. Generated content never changes these notes.",
            body: vertical(rows, spacing: 10),
            accessibilityLabel: "Your raw notes, read only"
        )
    }

    private func briefCard(_ brief: MeetingBrief) -> NSView {
        var sections: [NSView] = [overviewSection(brief.overview)]
        sections.append(itemSection("Key topics", symbolName: "bubble.left.and.bubble.right", items: brief.topics))
        sections.append(itemSection("Decisions", symbolName: "checkmark.seal", items: brief.decisions))
        sections.append(actionsSection(brief.actionItems))
        sections.append(itemSection("Open questions", symbolName: "questionmark.circle", items: brief.openQuestions))
        sections.append(warningsSection(brief.warnings))
        sections.append(provenanceSection(brief))
        return card(
            symbolName: "sparkles",
            title: "Generated meeting brief",
            subtitle: "AI-generated from the canonical transcript and the recorded source revision.",
            body: vertical(sections, spacing: 16),
            accessibilityLabel: "Generated meeting brief, read only"
        )
    }

    private func overviewSection(_ overview: String) -> NSView {
        section("Overview", symbolName: "text.alignleft", body: wrappingText(overview.isEmpty ? "No overview was generated." : overview, size: 13, color: overview.isEmpty ? .secondaryLabelColor : .labelColor))
    }

    private func itemSection(_ title: String, symbolName: String, items: [BriefItem]) -> NSView {
        let body: NSView
        if items.isEmpty {
            body = wrappingText("None recorded.", size: 13, color: .secondaryLabelColor)
        } else {
            body = vertical(items.map { briefItemRow($0) }, spacing: 10)
        }
        return section(title, symbolName: symbolName, body: body)
    }

    private func actionsSection(_ actions: [ActionItem]) -> NSView {
        let body: NSView
        if actions.isEmpty {
            body = wrappingText("No action items recorded.", size: 13, color: .secondaryLabelColor)
        } else {
            body = vertical(actions.map { actionRow($0) }, spacing: 10)
        }
        return section("Action items", symbolName: "checklist", body: body)
    }

    private func warningsSection(_ warnings: [String]) -> NSView {
        let body: NSView
        if warnings.isEmpty {
            body = wrappingText("No coverage warnings were recorded.", size: 13, color: .secondaryLabelColor)
        } else {
            body = vertical(warnings.map { warning in
                let label = wrappingText(warning, size: 13, color: .labelColor)
                let row = horizontal([icon("exclamationmark.triangle.fill", tint: .systemOrange), label], spacing: 8, alignment: .top)
                row.setAccessibilityLabel("Coverage warning: \(warning)")
                return row
            }, spacing: 8)
        }
        return section("Warnings and incomplete coverage", symbolName: "exclamationmark.triangle", body: body)
    }

    private func provenanceSection(_ brief: MeetingBrief) -> NSView {
        let generator = brief.generator
        let rows = [
            "Generated \(formattedDate(brief.createdAt))",
            "Language: \(brief.language)",
            "Transcript: \(brief.inputs.transcriptSegmentCount) segments · \(shortDigest(brief.inputs.transcriptSHA256))",
            "Raw-note revision: \(brief.inputs.rawNotesRevision)",
            "Local generator: \(generator.engine) · \(generator.modelID)",
            "Runtime: \(generator.runtimeVersion) · \(generator.quantization)",
            "Model provenance: \(generator.provenance)",
            generator.modelRevision.map { "Model revision: \($0)" },
            generator.endpoint.map { "Local endpoint: \($0)" },
        ].compactMap { $0 }.map { line in
            let field = text(line, size: 11, weight: .regular, color: .secondaryLabelColor)
            field.setAccessibilityLabel(line)
            return field
        }
        return section("Provenance", symbolName: "shield.lefthalf.filled", body: vertical(rows, spacing: 4))
    }

    private func briefItemRow(_ item: BriefItem) -> NSView {
        let copy = wrappingText(item.text, size: 13, color: .labelColor)
        let evidence = evidenceButtons(item.evidence)
        let row = vertical([copy, evidence], spacing: 6)
        row.setAccessibilityLabel("Generated item: \(item.text)")
        return row
    }

    private func actionRow(_ item: ActionItem) -> NSView {
        let copy = wrappingText(item.text, size: 13, color: .labelColor)
        var details: [String] = []
        if let owner = item.owner, !owner.isEmpty { details.append("Owner: \(owner)") }
        if let dueDate = item.dueDate, !dueDate.isEmpty { details.append("Due: \(dueDate)") }
        let metadata = details.isEmpty ? nil : text(details.joined(separator: " · "), size: 11, weight: .medium, color: .secondaryLabelColor)
        let views = [copy, metadata, evidenceButtons(item.evidence)].compactMap { $0 }
        let row = vertical(views, spacing: 6)
        row.setAccessibilityLabel("Action item: \(item.text)")
        return row
    }

    private func evidenceButtons(_ evidence: [EvidenceReference]) -> NSView {
        if evidence.isEmpty {
            return text("No linked transcript evidence.", size: 11, weight: .medium, color: .systemOrange)
        }
        return vertical(evidence.map { reference in
            let button = EvidenceButton(reference: reference)
            button.title = "Source \(reference.segmentID) · \(formattedTimestamp(reference.startMS)) · \(reference.speaker)"
            button.target = self
            button.action = #selector(showEvidence(_:))
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = .controlAccentColor
            button.setAccessibilityLabel("Show transcript evidence \(reference.segmentID), at \(formattedTimestamp(reference.startMS)), speaker \(reference.speaker)")
            button.setAccessibilityHelp("Opens this source reference in the transcript viewer.")
            return button
        }, spacing: 2)
    }

    private func stateCard(symbolName: String, title: String, detail: String, tone: NSColor = .controlAccentColor, progress: Bool = false) -> NSView {
        let symbol = iconTile(symbolName, tint: tone)
        let heading = text(title, size: 14, weight: .semibold)
        let copy = wrappingText(detail, size: 12, color: .secondaryLabelColor)
        var content: [NSView] = [horizontal([symbol, vertical([heading, copy], spacing: 3)], spacing: 10, alignment: .top)]
        if progress {
            let indicator = NSProgressIndicator()
            indicator.style = .bar
            indicator.isIndeterminate = true
            indicator.startAnimation(nil)
            indicator.setAccessibilityLabel("Meeting brief generation in progress")
            content.append(indicator)
        }
        return card(symbolName: symbolName, title: "Status", subtitle: "\(viewModel.state.title).", body: vertical(content, spacing: 10), accessibilityLabel: viewModel.state.accessibilityDescription)
    }

    private func section(_ title: String, symbolName: String, body: NSView) -> NSView {
        let heading = text(title, size: 14, weight: .semibold)
        let header = horizontal([icon(symbolName, tint: .controlAccentColor), heading], spacing: 7, alignment: .centerY)
        let result = vertical([header, body], spacing: 7)
        result.setAccessibilityLabel(title)
        return result
    }

    private func card(symbolName: String, title: String, subtitle: String, body: NSView, accessibilityLabel: String) -> NSView {
        let heading = text(title, size: 15, weight: .semibold)
        let header = horizontal([icon(symbolName, tint: .controlAccentColor), heading], spacing: 8, alignment: .centerY)
        let detail = wrappingText(subtitle, size: 12, color: .secondaryLabelColor)
        let card = BriefCardView(content: vertical([header, detail, body], spacing: 9))
        card.setAccessibilityLabel(accessibilityLabel)
        return card
    }

    private func add(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -48).isActive = true
    }

    private func text(_ value: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = .labelColor) -> NSTextField {
        let result = NSTextField(labelWithString: value)
        result.font = .systemFont(ofSize: size, weight: weight)
        result.textColor = color
        result.maximumNumberOfLines = 1
        result.lineBreakMode = .byTruncatingTail
        result.cell?.baseWritingDirection = .natural
        return result
    }

    private func wrappingText(_ value: String, size: CGFloat, color: NSColor) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: value)
        result.font = .systemFont(ofSize: size, weight: .regular)
        result.textColor = color
        result.lineBreakMode = .byWordWrapping
        result.cell?.baseWritingDirection = .natural
        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return result
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = alignment
        stack.spacing = spacing
        return stack
    }

    private func iconTile(_ symbolName: String, tint: NSColor) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 9
        tile.layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        tile.widthAnchor.constraint(equalToConstant: 34).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let image = NSImageView(image: symbol(symbolName, size: 14, weight: .semibold))
        image.contentTintColor = tint
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)
        NSLayoutConstraint.activate([
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    private func icon(_ name: String, tint: NSColor) -> NSImageView {
        let image = NSImageView(image: symbol(name, size: 13, weight: .medium))
        image.contentTintColor = tint
        image.setAccessibilityElement(false)
        return image
    }

    private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? NSImage()
    }

    private func formattedTimestamp(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    private func formattedDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return value }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    private func shortDigest(_ digest: String) -> String {
        digest.count > 16 ? "\(digest.prefix(12))…\(digest.suffix(4))" : digest
    }

    @objc private func primaryAction() {
        if viewModel.state.isProcessing {
            onCancel?()
        } else {
            onRegenerate?()
        }
    }

    @objc private func revealSession() { onReveal?() }

    @objc private func showEvidence(_ sender: EvidenceButton) {
        onShowEvidence?([sender.reference])
    }
}

private final class EvidenceButton: NSButton {
    let reference: EvidenceReference

    init(reference: EvidenceReference) {
        self.reference = reference
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class BriefCardView: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15),
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
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
