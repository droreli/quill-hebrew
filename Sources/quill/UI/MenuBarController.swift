import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the persistent control surface for the recorder.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let outputLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onOpenControls: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        // A fixed square avoids macOS collapsing a purely-image status item
        // into an almost invisible sliver when the menu bar is crowded.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        outputLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        outputLabel.isEnabled = false
        menu.addItem(outputLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        let openControls = NSMenuItem(
            title: "Open controls…",
            action: #selector(openControlsClicked),
            keyEquivalent: ","
        )
        openControls.image = Self.symbol("slider.horizontal.3")
        menu.addItem(openControls)

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        toggleItem.image = Self.symbol("record.circle")
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        openFolder.image = Self.symbol("folder")
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.image = Self.symbol("power")
        menu.addItem(quit)

        for item in [openControls, toggleItem, openFolder, quit] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.featherImage(size: 16)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Quill controls"
            button.setAccessibilityLabel("Quill controls")
        }
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows only the feather (red while recording); the elapsed
    /// counter lives in the menu's state label. Call once a second while
    /// recording.
    func update(recording: Bool, elapsed: String?) {
        stateLabel.title = recording ? "Recording · \(elapsed ?? "0:00")" : "Ready"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        toggleItem.image = Self.symbol(recording ? "stop.circle.fill" : "record.circle")
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    /// Make the active mode visible at the only persistent control surface.
    /// Changing it is deliberately explicit (the config file or --mix-tracks)
    /// so a meeting cannot silently lose the original speaker-separated flow.
    func setOutputMode(_ output: Config.RecordingOutput) {
        outputLabel.title = switch output {
        case .separate:
            "Clean tracks · labels hidden"
        case .separateWithMixedExport:
            "Clean tracks + mixed listening copy"
        }
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    static func featherImage(size: CGFloat) -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: size, height: size)
        return image
    }

    /// A real Dock icon for the foreground app. Keep it code-generated so the
    /// standalone executable does not rely on an app bundle or external asset.
    static func appIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let inset = size * 0.04
        let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(
            roundedRect: tile,
            xRadius: size * 0.23,
            yRadius: size * 0.23
        ).fill()

        if let feather = featherImage(size: size * 0.58) {
            feather.isTemplate = false
            NSColor.white.set()
            feather.draw(
                in: NSRect(
                    x: (size - feather.size.width) / 2,
                    y: (size - feather.size.height) / 2,
                    width: feather.size.width,
                    height: feather.size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
        image.unlockFocus()
        return image
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
            .init(pointSize: 13, weight: .medium)
        )
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openControlsClicked() { onOpenControls?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
}
