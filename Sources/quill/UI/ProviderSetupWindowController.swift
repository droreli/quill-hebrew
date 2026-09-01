import AppKit

/// Native setup for the optional LM Studio provider. The controller exposes
/// callbacks only: it never writes preferences or starts, installs, updates,
/// downloads, or contacts LM Studio itself.
@MainActor
final class ProviderSetupWindowController: NSWindowController, NSTextFieldDelegate {
    var onConfigurationChanged: ((LMStudioProviderConfiguration) -> Void)?
    var onCheckReadiness: ((LMStudioProviderConfiguration) -> Void)?

    private var configuration: LMStudioProviderConfiguration
    private let enabled = NSButton(checkboxWithTitle: "Enable LM Studio provider", target: nil, action: nil)
    private let endpoint = NSTextField(string: "")
    private let model = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(wrappingLabelWithString: "Disabled. Recording and transcription do not depend on this provider.")
    private let check = NSButton(title: "Check availability", target: nil, action: nil)

    init(configuration: LMStudioProviderConfiguration = .init()) {
        self.configuration = configuration
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 390),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Local meeting brief provider"
        window.minSize = NSSize(width: 460, height: 350)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The owner supplies a readiness result after its explicit, injected
    /// probe. This controller only renders it.
    func update(readiness: ProviderReadiness) {
        switch readiness {
        case .disabled:
            status.stringValue = "Disabled. Recording and transcription do not depend on this provider."
        case let .ready(inventory):
            setModelChoices(reported: inventory.models.map(\.id))
            status.stringValue = inventory.selectedModelIsAvailable
                ? "Available locally. Model identity is reported by LM Studio; no checksum was verified."
                : "LM Studio is available, but the selected model was not reported. Choose a listed model or load it in LM Studio."
        case let .unavailable(failure):
            switch failure {
            case let .invalidConfiguration(message), let .providerUnavailable(message), let .invalidResponse(message):
                status.stringValue = message
            case .timedOut:
                status.stringValue = "The local provider did not respond in time. Recording and transcription remain available."
            }
        }
    }

    private func build() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = content

        enabled.target = self
        enabled.action = #selector(changed)
        enabled.setAccessibilityLabel("Enable optional LM Studio meeting brief provider")
        endpoint.delegate = self
        endpoint.placeholderString = LMStudioProviderConfiguration.defaultEndpoint
        endpoint.setAccessibilityLabel("LM Studio loopback endpoint")
        endpoint.setAccessibilityHelp("Only literal 127.0.0.1 or ::1 HTTP endpoints are accepted.")
        model.target = self
        model.action = #selector(changed)
        model.setAccessibilityLabel("Meeting brief model")
        check.target = self
        check.action = #selector(checkReadiness)
        check.bezelStyle = .rounded
        check.setAccessibilityLabel("Check local provider availability")

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3

        let stack = NSStackView(views: [
            heading("Optional local provider", detail: "Quill can ask an LM Studio server already running on this Mac for a meeting brief after a transcript is complete."),
            divider(),
            enabled,
            fieldRow(title: "Loopback endpoint", detail: "HTTP only · literal 127.0.0.1 or ::1", field: endpoint),
            fieldRow(title: "Model", detail: "Recommended personal profile", field: model),
            status,
            divider(),
            check,
            NSTextField(wrappingLabelWithString: "Quill never starts, installs, updates, or downloads LM Studio or models. If it is unavailable, recording and transcription continue normally."),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])
        (stack.arrangedSubviews.last as? NSTextField)?.font = .systemFont(ofSize: 11)
        (stack.arrangedSubviews.last as? NSTextField)?.textColor = .tertiaryLabelColor
    }

    private func apply(_ configuration: LMStudioProviderConfiguration) {
        enabled.state = configuration.isEnabled ? .on : .off
        endpoint.stringValue = configuration.endpoint
        setModelChoices(reported: [])
        selectModel(configuration.selectedModelID)
        refreshEnabledState()
    }

    private func setModelChoices(reported: [String]) {
        let choices = Array(Set([LMStudioProviderConfiguration.recommendedPersonalModelID] + reported)).sorted { lhs, rhs in
            if lhs == LMStudioProviderConfiguration.recommendedPersonalModelID { return true }
            if rhs == LMStudioProviderConfiguration.recommendedPersonalModelID { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        model.removeAllItems()
        model.addItems(withTitles: choices)
        selectModel(configuration.selectedModelID)
    }

    private func selectModel(_ id: String) {
        if model.itemTitles.contains(id) {
            model.selectItem(withTitle: id)
        } else {
            model.addItem(withTitle: id)
            model.selectItem(withTitle: id)
        }
    }

    private func refreshEnabledState() {
        let isEnabled = enabled.state == .on
        endpoint.isEnabled = isEnabled
        model.isEnabled = isEnabled
        check.isEnabled = isEnabled && (try? LoopbackProviderEndpoint(validating: endpoint.stringValue)) != nil
        if !isEnabled {
            update(readiness: .disabled)
        } else if check.isEnabled == false {
            status.stringValue = "Enter a literal HTTP loopback endpoint, such as http://127.0.0.1:1234."
        }
    }

    private func publishConfiguration() {
        configuration.isEnabled = enabled.state == .on
        configuration.endpoint = endpoint.stringValue
        configuration.selectedModelID = model.titleOfSelectedItem ?? LMStudioProviderConfiguration.recommendedPersonalModelID
        onConfigurationChanged?(configuration)
    }

    @objc private func changed() {
        publishConfiguration()
        refreshEnabledState()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === endpoint else { return }
        publishConfiguration()
        refreshEnabledState()
    }

    @objc private func checkReadiness() {
        publishConfiguration()
        guard configuration.isEnabled,
              (try? LoopbackProviderEndpoint(validating: configuration.endpoint)) != nil
        else {
            refreshEnabledState()
            return
        }
        status.stringValue = "Checking the local provider…"
        onCheckReadiness?(configuration)
    }

    private func heading(_ title: String, detail: String) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 20, weight: .semibold)
        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.font = .systemFont(ofSize: 12)
        detailField.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleField, detailField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func fieldRow(title: String, detail: String, field: NSView) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        let detailField = NSTextField(labelWithString: detail)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .tertiaryLabelColor
        let labels = NSStackView(views: [titleField, detailField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let row = NSStackView(views: [labels, NSView(), field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalToConstant: 470).isActive = true
        return line
    }
}
