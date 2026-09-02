import AppKit

/// A native macOS pre-flight centre: explicit recording state, grouped choices,
/// and one clear action. It keeps the menu-bar workflow and callbacks intact.
@MainActor
final class ControlsWindowController: NSWindowController {
    var onOptionsChanged: ((RecordingOptions) -> Void)?
    var onToggleRecording: (() -> Void)?
    var onOpenRecordings: (() -> Void)?
    var onOpenLibrary: (() -> Void)?
    var onOpenSession: (() -> Void)?
    var onOpenNotes: (() -> Void)?
    var onOpenBrief: (() -> Void)?
    var onOpenProviderSetup: (() -> Void)?

    private var options: RecordingOptions
    private let language = NSPopUpButton(frame: .zero, pullsDown: false)
    private let engine = NSPopUpButton(frame: .zero, pullsDown: false)
    private let timestamps = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let speakers = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let mixedAudio = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let recordingPath = NSTextField(labelWithString: "")
    private let sessionPath = NSTextField(labelWithString: "No completed recording yet")
    private let engineDetail = NSTextField(labelWithString: "")
    private let statusPill = RecordingStatusPill()
    private let startStop = NSButton(title: "Start recording", target: nil, action: nil)
    private let sessionButton = NSButton(title: "Reveal", target: nil, action: nil)
    private let libraryButton = NSButton(title: "Browse meetings…", target: nil, action: nil)
    private let meetingNotesButton = NSButton(title: "Meeting notes…", target: nil, action: nil)
    private let meetingBriefButton = NSButton(title: "Meeting brief…", target: nil, action: nil)
    private let providerSetupButton = NSButton(title: "Provider setup…", target: nil, action: nil)
    private let briefAvailabilityLabel = NSTextField(wrappingLabelWithString: "")

    init(root: URL, options: RecordingOptions) {
        self.options = options
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Quill"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // The controls are intentionally compact by default, while the scroll
        // view below keeps every setting reachable at smaller window heights.
        window.minSize = NSSize(width: 560, height: 480)
        window.isReleasedWhenClosed = false
        // A new name prevents a previously saved oversized frame from masking
        // the new compact default on upgrade.
        let frameAutosaveName = "QuillControlsWindowV2"
        if !window.setFrameUsingName(frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(frameAutosaveName)
        super.init(window: window)
        build(root: root)
        apply(options)
        update(isRecording: false, session: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(isRecording: Bool, session: URL?) {
        applyRecordingState(isRecording)
        [language, engine, timestamps, speakers, mixedAudio].forEach { $0.isEnabled = !isRecording }
        if let session {
            sessionPath.stringValue = session.lastPathComponent
            sessionPath.toolTip = session.path
            sessionPath.setAccessibilityValue(session.path)
            sessionButton.isEnabled = true
        }
        updateMeetingIntelligence(isRecording: isRecording, session: session)
    }

    func updateMeetingIntelligence(isRecording: Bool, session: URL?) {
        let transcriptReady = session.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
        } ?? false
        let availability = MeetingBriefAvailability(
            isRecording: isRecording,
            transcriptReady: transcriptReady
        )
        meetingBriefButton.title = availability.buttonTitle
        meetingBriefButton.isEnabled = availability.canOpen
        meetingBriefButton.setAccessibilityHelp(availability.guidance)
        briefAvailabilityLabel.stringValue = availability.guidance
        briefAvailabilityLabel.setAccessibilityValue(availability.guidance)
    }

    private func build(root: URL) {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = content

        configureControls()
        recordingPath.stringValue = abbreviatedPath(root)
        recordingPath.toolTip = root.path
        recordingPath.setAccessibilityValue(root.path)
        sessionPath.lineBreakMode = .byTruncatingMiddle
        sessionPath.textColor = .secondaryLabelColor

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityLabel("Quill controls")

        // NSScrollView starts an ordinary AppKit document view at its bottom.
        // A flipped document keeps the pre-flight header at the top on every
        // fresh open, matching the visual reading order of this form.
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 48),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])

        [header(), recordingHero(), recordingSetupCard(), readingAndOutputCard(), storageCard(), meetingIntelligenceCard()].forEach {
            stack.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func configureControls() {
        language.addItems(withTitles: ["Hebrew + English", "Hebrew only", "English only"])
        engine.addItems(withTitles: ["Hebrew MLX — Apple GPU", "English Parakeet — local", "Hebrew CPU — fallback"])
        for control in [language, engine] {
            control.controlSize = .large
            control.target = self
            control.action = #selector(changed)
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        language.setAccessibilityLabel("Transcription language")
        engine.setAccessibilityLabel("Transcription engine")

        for (control, title, help) in [
            (timestamps, "Show timestamps", "Add a time marker to each transcript segment."),
            (speakers, "Show speaker labels", "Label microphone and system-audio speakers."),
            (mixedAudio, "Save a listening copy", "Exports mixed.m4a. Clean tracks remain the transcript source."),
        ] {
            control.setButtonType(.switch)
            control.title = ""
            control.target = self
            control.action = #selector(changed)
            control.setAccessibilityLabel(title)
            control.setAccessibilityHelp(help)
        }
        sessionButton.target = self
        sessionButton.action = #selector(revealSession)
        sessionButton.bezelStyle = .rounded
        sessionButton.image = symbol("arrow.up.forward.app", size: 12, weight: .medium)
        sessionButton.imagePosition = .imageLeading
        sessionButton.setAccessibilityLabel("Reveal latest recording")

        startStop.target = self
        startStop.action = #selector(toggle)
        startStop.bezelStyle = .rounded
        startStop.controlSize = .large
        startStop.imagePosition = .imageLeading
        startStop.heightAnchor.constraint(equalToConstant: 64).isActive = true
        startStop.keyEquivalent = " "
        startStop.keyEquivalentModifierMask = []
        startStop.toolTip = "Start or stop recording. Control Command R works globally."
        startStop.setAccessibilityHelp("Starts or stops local microphone and system-audio recording. Control Command R works from anywhere.")

        libraryButton.target = self
        libraryButton.action = #selector(openLibrary)
        libraryButton.bezelStyle = .rounded
        libraryButton.image = symbol("rectangle.stack", size: 12, weight: .medium)
        libraryButton.imagePosition = .imageLeading
        libraryButton.setAccessibilityLabel("Browse completed meetings")

        meetingNotesButton.target = self
        meetingNotesButton.action = #selector(openNotes)
        meetingNotesButton.image = symbol("note.text", size: 12, weight: .medium)
        meetingNotesButton.setAccessibilityHelp("Write private notes for the current or latest meeting.")
        meetingBriefButton.target = self
        meetingBriefButton.action = #selector(openBrief)
        meetingBriefButton.image = symbol("sparkles", size: 12, weight: .medium)
        providerSetupButton.target = self
        providerSetupButton.action = #selector(openProviderSetup)
        providerSetupButton.image = symbol("cpu", size: 12, weight: .medium)
        for button in [meetingNotesButton, meetingBriefButton, providerSetupButton] {
            button.bezelStyle = .rounded
            button.imagePosition = .imageLeading
        }
        briefAvailabilityLabel.font = .systemFont(ofSize: 11, weight: .regular)
        briefAvailabilityLabel.textColor = .secondaryLabelColor
        briefAvailabilityLabel.maximumNumberOfLines = 2
        briefAvailabilityLabel.setAccessibilityLabel("Meeting brief availability")
    }

    private func header() -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 11
        tile.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        tile.widthAnchor.constraint(equalToConstant: 42).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let image = NSImageView(image: MenuBarController.featherImage(size: 21) ?? symbol("waveform", size: 18, weight: .semibold)!)
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)
        NSLayoutConstraint.activate([
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 21),
            image.heightAnchor.constraint(equalToConstant: 21),
        ])
        let title = label("Quill", size: 24, weight: .semibold)
        let subtitle = label("Private meeting capture", size: 12, weight: .medium, color: .secondaryLabelColor)
        let detail = label("Microphone + system audio · processed locally", size: 11, weight: .regular, color: .tertiaryLabelColor)
        let copy = vertical([title, subtitle, detail], spacing: 1)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return horizontal([tile, copy, spacer, statusPill], spacing: 12, alignment: .centerY)
    }

    private func recordingSetupCard() -> NSView {
        let selectors = horizontal([
            selectorColumn("Meeting language", "This selects the decoding language for the next recording.", language),
            selectorColumn("Local model", "Choose the model that runs on this Mac.", engine, trailingDetail: engineDetail),
        ], spacing: 14, alignment: .top)
        selectors.distribution = .fillEqually
        return card("waveform", "Recording setup", "For Hebrew + English, use the Hebrew MLX model. Use Parakeet for English-only meetings.", selectors, "Recording setup")
    }

    private func readingAndOutputCard() -> NSView {
        let rows = vertical([
            preferenceRow("clock", "Show timestamps", "Add a time marker to each transcript segment.", timestamps),
            separator(),
            preferenceRow("person.2", "Show speaker labels", "Label microphone and system-audio speakers.", speakers),
            separator(),
            preferenceRow("speaker.wave.2", "Save a listening copy", "Exports mixed.m4a; clean tracks remain the transcript source.", mixedAudio),
        ], spacing: 0)
        return card("text.bubble", "Reading & output", "These choices are saved as your defaults for future recordings.", rows, "Reading and output options")
    }

    private func storageCard() -> NSView {
        let rows = vertical([
            locationRow("folder", "Recording folder", recordingPath, action: #selector(revealRecordings)),
            separator(),
            locationRow("doc.text", "Last recording", sessionPath, action: #selector(revealSession), button: sessionButton),
            separator(),
            locationRow("rectangle.stack", "Meeting library", NSTextField(labelWithString: "Browse a selected completed recording, its transcript, source tracks, listening copy, notes, and brief."), action: #selector(openLibrary), button: libraryButton),
        ], spacing: 0)
        return card("internaldrive", "Files", "Your recordings stay in a local folder you control.", rows, "Recording files")
    }

    private func meetingIntelligenceCard() -> NSView {
        let actions = horizontal(
            [meetingNotesButton, meetingBriefButton, providerSetupButton],
            spacing: 8,
            alignment: .centerY
        )
        let body = vertical([actions, briefAvailabilityLabel], spacing: 7)
        return card(
            "sparkles",
            "Meeting intelligence",
            "Write private notes while recording. AI Brief uses only the finished transcript and those notes — never audio.",
            body,
            "Meeting intelligence"
        )
    }

    private func recordingHero() -> NSView {
        let helper = label("⌃⌘R starts or stops recording from anywhere", size: 11, weight: .regular, color: .tertiaryLabelColor)
        helper.alignment = .center
        let title = label("Ready when you are", size: 15, weight: .semibold)
        title.alignment = .center
        let detail = label("Capture stays on this Mac. Stop when the meeting ends; canonical transcription follows safely.", size: 11, weight: .regular, color: .secondaryLabelColor)
        detail.alignment = .center
        let column = vertical([title, detail, startStop, helper], spacing: 8)
        column.alignment = .centerX
        startStop.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return RoundedCardView(content: column)
    }

    private func card(_ symbolName: String, _ title: String, _ subtitle: String, _ body: NSView, _ accessibilityLabel: String) -> NSView {
        let icon = NSImageView(image: symbol(symbolName, size: 14, weight: .semibold)!)
        icon.contentTintColor = .controlAccentColor
        let heading = label(title, size: 14, weight: .semibold)
        let copy = NSTextField(wrappingLabelWithString: subtitle)
        copy.font = .systemFont(ofSize: 12, weight: .regular)
        copy.textColor = .secondaryLabelColor
        let content = vertical([horizontal([icon, heading], spacing: 7, alignment: .centerY), copy, body], spacing: 8)
        let result = RoundedCardView(content: content)
        result.setAccessibilityLabel(accessibilityLabel)
        return result
    }

    private func selectorColumn(_ title: String, _ detail: String, _ control: NSView, trailingDetail: NSTextField? = nil) -> NSView {
        let heading = label(title, size: 11, weight: .semibold, color: .secondaryLabelColor)
        let help = label(detail, size: 11, weight: .regular, color: .tertiaryLabelColor)
        let parts = [heading, control, trailingDetail, help].compactMap { $0 }
        let stack = vertical(parts, spacing: 5)
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        if let trailingDetail {
            trailingDetail.font = .systemFont(ofSize: 11, weight: .medium)
            trailingDetail.textColor = .secondaryLabelColor
            trailingDetail.lineBreakMode = .byTruncatingTail
        }
        return stack
    }

    private func preferenceRow(_ symbolName: String, _ title: String, _ subtitle: String, _ control: NSButton) -> NSView {
        let heading = label(title, size: 13, weight: .medium)
        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.font = .systemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        let copy = vertical([heading, detail], spacing: 2)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = horizontal([iconTile(symbolName), copy, spacer, control], spacing: 10, alignment: .centerY)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        return row
    }

    private func locationRow(_ symbolName: String, _ title: String, _ path: NSTextField, action: Selector, button: NSButton? = nil) -> NSView {
        let button = button ?? NSButton(title: "Reveal", target: self, action: action)
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        if button.image == nil {
            button.image = symbol("arrow.up.forward.app", size: 12, weight: .medium)
            button.imagePosition = .imageLeading
        }
        let heading = label(title, size: 13, weight: .medium)
        path.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        let copy = vertical([heading, path], spacing: 2)
        copy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = horizontal([iconTile(symbolName), copy, button], spacing: 10, alignment: .centerY)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        return row
    }

    private func iconTile(_ name: String) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 8
        tile.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        tile.widthAnchor.constraint(equalToConstant: 30).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let image = NSImageView(image: symbol(name, size: 13, weight: .medium)!)
        image.contentTintColor = .controlAccentColor
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)
        NSLayoutConstraint.activate([
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    private func apply(_ options: RecordingOptions) {
        let languageIndex: Int = switch options.language {
        case .automatic: 0
        case .hebrew: 1
        case .english: 2
        }
        let engineIndex: Int = switch options.engine {
        case .hebrewMLX: 0
        case .parakeet: 1
        case .hebrewCPU: 2
        }
        language.selectItem(at: languageIndex)
        engine.selectItem(at: engineIndex)
        timestamps.state = options.showTimestamps ? .on : .off
        speakers.state = options.showSpeakerLabels ? .on : .off
        mixedAudio.state = options.output == .separateWithMixedExport ? .on : .off
        updateEngineDetail()
    }

    private func applyRecordingState(_ recording: Bool) {
        statusPill.set(recording: recording)
        startStop.title = recording ? "Stop recording" : "Start recording"
        startStop.image = symbol(recording ? "stop.circle.fill" : "record.circle", size: 16, weight: .semibold)
        startStop.bezelColor = recording ? .systemRed : .controlAccentColor
        startStop.setAccessibilityLabel(startStop.title)
    }

    private func updateEngineDetail() {
        engineDetail.stringValue = switch options.engine {
        case .hebrewMLX: "Hebrew + mixed speech · Whisper Large V3 Turbo · Apple GPU"
        case .parakeet: "English-only meetings · Parakeet TDT 0.6B v2 · Core ML"
        case .hebrewCPU: "Hebrew fallback · local CPU · slower"
        }
    }

    private func abbreviatedPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = .labelColor) -> NSTextField {
        let result = NSTextField(labelWithString: text)
        result.font = .systemFont(ofSize: size, weight: weight)
        result.textColor = color
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

    private func separator() -> NSView {
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor.separatorColor.cgColor
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return rule
    }

    private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    @objc private func changed() {
        let selectedLanguage: TranscriptionLanguage = switch language.indexOfSelectedItem {
        case 1: .hebrew
        case 2: .english
        default: .automatic
        }
        if selectedLanguage == .english, options.engine == .hebrewMLX { engine.selectItem(at: 1) }
        if selectedLanguage == .hebrew, options.engine == .parakeet { engine.selectItem(at: 0) }
        options.language = selectedLanguage
        options.engine = switch engine.indexOfSelectedItem { case 1: .parakeet; case 2: .hebrewCPU; default: .hebrewMLX }
        options.showTimestamps = timestamps.state == .on
        options.showSpeakerLabels = speakers.state == .on
        options.output = mixedAudio.state == .on ? .separateWithMixedExport : .separate
        updateEngineDetail()
        onOptionsChanged?(options)
    }

    @objc private func toggle() { onToggleRecording?() }
    @objc private func revealRecordings() { onOpenRecordings?() }
    @objc private func openLibrary() { onOpenLibrary?() }
    @objc private func revealSession() { onOpenSession?() }
    @objc private func openNotes() { onOpenNotes?() }
    @objc private func openBrief() { onOpenBrief?() }
    @objc private func openProviderSetup() { onOpenProviderSetup?() }
}

private final class RoundedCardView: NSView {
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
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshAppearance() }
    private func refreshAppearance() {
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class RecordingStatusPill: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "Ready")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot); addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 28),
        ])
        set(recording: false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    func set(recording: Bool) {
        label.stringValue = recording ? "Recording" : "Ready"
        label.textColor = recording ? .systemRed : .secondaryLabelColor
        setAccessibilityLabel(recording ? "Recording in progress" : "Ready to record")
        layer?.cornerRadius = 14
        layer?.backgroundColor = (recording ? NSColor.systemRed : NSColor.quaternaryLabelColor).withAlphaComponent(recording ? 0.15 : 0.12).cgColor
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = (recording ? NSColor.systemRed : NSColor.systemGreen).cgColor
    }
}
