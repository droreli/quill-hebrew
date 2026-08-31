import AppKit

/// A deliberately small pre-flight window. The menu-bar button remains the
/// fastest way to start/stop; this window makes the consequential choices
/// visible before a recording starts without exposing model identifiers.
@MainActor
final class ControlsWindowController: NSWindowController {
    var onOptionsChanged: ((RecordingOptions) -> Void)?
    var onToggleRecording: (() -> Void)?
    var onOpenRecordings: (() -> Void)?
    var onOpenSession: (() -> Void)?

    private var options: RecordingOptions
    private let language = NSPopUpButton(frame: .zero, pullsDown: false)
    private let engine = NSPopUpButton(frame: .zero, pullsDown: false)
    private let timestamps = NSButton(checkboxWithTitle: "Show timestamps in the reading view", target: nil, action: nil)
    private let speakers = NSButton(checkboxWithTitle: "Show speaker labels in the reading view", target: nil, action: nil)
    private let mixedAudio = NSButton(checkboxWithTitle: "Also save mixed.m4a for listening", target: nil, action: nil)
    private let recordingPath = NSTextField(labelWithString: "")
    private let sessionPath = NSTextField(labelWithString: "No recording completed yet")
    private let startStop = NSButton(title: "Start recording", target: nil, action: nil)
    private let sessionButton = NSButton(title: "Reveal latest session", target: nil, action: nil)

    init(root: URL, options: RecordingOptions) {
        self.options = options
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 570),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quill controls"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build(root: root)
        apply(options)
        sessionButton.isEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(isRecording: Bool, session: URL?) {
        startStop.title = isRecording ? "Stop recording" : "Start recording"
        language.isEnabled = !isRecording
        engine.isEnabled = !isRecording
        timestamps.isEnabled = !isRecording
        speakers.isEnabled = !isRecording
        mixedAudio.isEnabled = !isRecording
        if let session {
            sessionPath.stringValue = session.path
            sessionButton.isEnabled = true
        }
    }

    private func build(root: URL) {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
        ])

        let title = NSTextField(labelWithString: "Meeting recording")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(label("Quill keeps your mic and system audio as separate clean tracks, then merges their timed transcript into one reading view. This keeps overlap understandable."))

        language.addItems(withTitles: ["Automatic / mixed", "Hebrew", "English"])
        language.target = self
        language.action = #selector(changed)
        stack.addArrangedSubview(row("Language", language))

        engine.addItems(withTitles: ["Hebrew GPU (recommended)", "English local", "Hebrew CPU fallback"])
        engine.target = self
        engine.action = #selector(changed)
        stack.addArrangedSubview(row("Transcription", engine))

        for control in [timestamps, speakers, mixedAudio] {
            control.target = self
            control.action = #selector(changed)
            stack.addArrangedSubview(control)
        }
        stack.addArrangedSubview(label("The optional mixed file is convenient for playback, but overlapping voices can be less clear. It is never used as the primary transcript."))

        recordingPath.stringValue = root.path
        recordingPath.lineBreakMode = .byTruncatingMiddle
        sessionPath.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(section("Recording folder", recordingPath, title: "Reveal recordings", action: #selector(revealRecordings)))
        stack.addArrangedSubview(section("Latest recording / transcript", sessionPath, title: "Reveal latest session", action: #selector(revealSession), button: sessionButton))

        startStop.target = self
        startStop.action = #selector(toggle)
        startStop.bezelStyle = .rounded
        stack.addArrangedSubview(startStop)
    }

    private func apply(_ options: RecordingOptions) {
        let languageIndex: Int = switch options.language {
        case .automatic: 0
        case .hebrew: 1
        case .english: 2
        }
        language.selectItem(at: languageIndex)
        let engineIndex: Int = switch options.engine {
        case .hebrewMLX: 0
        case .parakeet: 1
        case .hebrewCPU: 2
        }
        engine.selectItem(at: engineIndex)
        timestamps.state = options.showTimestamps ? .on : .off
        speakers.state = options.showSpeakerLabels ? .on : .off
        mixedAudio.state = options.output == .separateWithMixedExport ? .on : .off
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let stack = NSStackView(views: [NSTextField(labelWithString: title), control])
        stack.orientation = .horizontal
        stack.spacing = 18
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.arrangedSubviews[0].widthAnchor.constraint(equalToConstant: 120).isActive = true
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        return stack
    }

    private func section(_ title: String, _ path: NSTextField, title buttonTitle: String, action: Selector, button: NSButton? = nil) -> NSView {
        let button = button ?? NSButton(title: buttonTitle, target: self, action: action)
        button.target = self
        button.action = action
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        let line = NSStackView(views: [path, button])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let result = NSStackView(views: [heading, line])
        result.orientation = .vertical
        result.spacing = 3
        return result
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 0
        return field
    }

    @objc private func changed() {
        let selectedLanguage: TranscriptionLanguage = switch language.indexOfSelectedItem {
        case 1: .hebrew
        case 2: .english
        default: .automatic
        }
        // Keep the first useful choice friendly: Hebrew/automatic starts with
        // the proven GPU model; selecting English switches that default to the
        // local English engine. The CPU fallback is never overridden.
        if selectedLanguage == .english, options.engine == .hebrewMLX {
            engine.selectItem(at: 1)
        } else if selectedLanguage == .hebrew, options.engine == .parakeet {
            engine.selectItem(at: 0)
        }
        options.language = selectedLanguage
        options.engine = switch engine.indexOfSelectedItem {
        case 1: .parakeet
        case 2: .hebrewCPU
        default: .hebrewMLX
        }
        options.showTimestamps = timestamps.state == .on
        options.showSpeakerLabels = speakers.state == .on
        options.output = mixedAudio.state == .on ? .separateWithMixedExport : .separate
        onOptionsChanged?(options)
    }

    @objc private func toggle() { onToggleRecording?() }
    @objc private func revealRecordings() { onOpenRecordings?() }
    @objc private func revealSession() { onOpenSession?() }
}
