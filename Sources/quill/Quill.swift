import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self, VerifyMix.self, VerifyMLX.self, Retranscribe.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    @Flag(
        name: .long,
        help: "Also render mixed.m4a after each recording for listening. Quill still transcribes the two clean tracks and merges them chronologically, so overlapping voices stay clearer."
    )
    var exportMixedAudio = false

    @Flag(name: .long, help: "Open the controls window without starting a recording.")
    var controlsOnly = false

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        // Quill remains a menu-bar recorder, but is a regular foreground app
        // so it also has an unmistakable Dock icon while it is running.
        app.setActivationPolicy(.regular)
        app.applicationIconImage = MenuBarController.appIcon(size: 512)

        let output = exportMixedAudio
            ? Config.RecordingOutput.separateWithMixedExport
            : Config.recordingOutput()
        let controller = AppController(root: root, options: Config.recordingOptions(outputOverride: output))
        if controlsOnly { controller.showControls() }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private var options: RecordingOptions
    private let menuBar = MenuBarController()
    private let transcription: TranscriptionCoordinator
    private let controls: ControlsWindowController
    private var session: RecordingSession?
    private var latestSession: URL?
    private var ticker: Timer?

    init(root: URL, options: RecordingOptions) {
        self.root = root
        self.options = options
        self.transcription = TranscriptionCoordinator()
        self.controls = ControlsWindowController(root: root, options: options)
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenControls = { [weak self] in self?.controls.show() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)
        menuBar.setOutputMode(options.output)
        controls.onOptionsChanged = { [weak self] options in
            do {
                try Config.saveRecordingDefaults(options)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: couldn't save Quill defaults: \(error)\n".utf8
                ))
            }
            self?.options = options
            self?.menuBar.setOutputMode(options.output)
        }
        controls.onToggleRecording = { [weak self] in self?.toggle() }
        controls.onOpenRecordings = { [weak self] in self?.openFolder() }
        controls.onOpenSession = { [weak self] in self?.openLatestSession() }
        controls.update(isRecording: false, session: nil)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        NSApp.terminate(nil)
    }

    func showControls() { controls.show() }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(
                root: root,
                options: options
            )
            try newSession.start()
            session = newSession
            latestSession = newSession.dir
            controls.update(isRecording: true, session: newSession.dir)
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        controls.update(isRecording: false, session: dir)
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private func openLatestSession() {
        guard let latestSession else { return }
        NSWorkspace.shared.open(latestSession)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
