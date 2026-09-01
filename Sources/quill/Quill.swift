import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self, VerifyMix.self, VerifyMLX.self, Retranscribe.self, Brief.self],
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
        app.delegate = controller
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

/// Generate a post-transcript local meeting brief. This command is deliberately
/// separate from recording and never opens any audio file: it submits only the
/// canonical transcript plus the frozen raw-note revision to an already-running
/// local LM Studio server.
struct Brief: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brief",
        abstract: "Explicitly generate a local meeting brief for one completed transcript."
    )

    @Argument(help: "Path to a completed Quill session directory containing transcript.json.")
    var sessionDirectory: String

    @Flag(name: .long, help: "Explicitly enable local LM Studio generation for this invocation; nothing runs without this flag.")
    var enable = false

    @Option(name: .long, help: "Literal loopback LM Studio endpoint for this invocation.")
    var endpoint: String?

    @Option(name: .long, help: "LM Studio model ID for this invocation.")
    var model: String?

    func run() async throws {
        guard enable else {
            throw ValidationError("Refusing to generate a brief without --enable. This command never enables or saves provider settings implicitly.")
        }
        let directory = URL(
            fileURLWithPath: (sessionDirectory as NSString).expandingTildeInPath,
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.json").path) else {
            throw ValidationError("no transcript.json in completed session: \(directory.path)")
        }
        let configuration = try Config.lmStudioConfiguration(
            enabledOverride: true,
            endpointOverride: endpoint,
            modelOverride: model
        )
        let coordinator = PostMeetingCoordinator(
            engine: LMStudioSummarizationEngine(configuration: configuration)
        )
        let (stream, continuation) = AsyncStream<PostMeetingCoordinator.State>.makeStream()
        await coordinator.setStatusHandler { state in continuation.yield(state) }
        defer { continuation.finish() }
        try await coordinator.enqueue(directory)
        for await state in stream {
            switch state {
            case .ready:
                print("✓ meeting brief written to \(MeetingBriefStore(sessionDirectory: directory).artifactsDirectory.path)")
                return
            case let .failed(_, message):
                throw ValidationError(message)
            case .cancelled:
                throw CancellationError()
            case .idle, .preparing, .generating:
                continue
            }
        }
        throw ValidationError("brief generation ended without a terminal result")
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let root: URL
    private var options: RecordingOptions
    private let menuBar = MenuBarController()
    private let transcription: TranscriptionCoordinator
    private let controls: ControlsWindowController
    private var globalRecordHotKey: GlobalHotKey?
    private var session: RecordingSession?
    private var latestSession: URL?
    private var ticker: Timer?
    private lazy var notesWindow = MeetingNotesWindowController()
    private lazy var briefWindow = MeetingBriefWindowController(viewModel: briefViewModel)
    private lazy var providerSetup = ProviderSetupWindowController(configuration: Config.lmStudioProvider())
    private let briefViewModel = MeetingBriefViewModel()
    private var noteStore: SessionNoteStore?
    private var noteSessionID: String?
    private var noteSessionStartedAt: Date?
    private var briefCoordinator: PostMeetingCoordinator?

    init(root: URL, options: RecordingOptions) {
        self.root = root
        self.options = options
        self.transcription = TranscriptionCoordinator()
        self.controls = ControlsWindowController(root: root, options: options)
        self.globalRecordHotKey = nil
        super.init()
        globalRecordHotKey = GlobalHotKey.recordingToggle { [weak self] in
            self?.toggle()
        }
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenControls = { [weak self] in self?.controls.show() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onOpenNotes = { [weak self] in self?.openNotes() }
        menuBar.onOpenBrief = { [weak self] in self?.openBrief() }
        menuBar.onOpenProviderSetup = { [weak self] in self?.providerSetup.show() }
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
        controls.onOpenNotes = { [weak self] in self?.openNotes() }
        controls.onOpenBrief = { [weak self] in self?.openBrief() }
        controls.onOpenProviderSetup = { [weak self] in self?.providerSetup.show() }
        latestSession = Self.latestCompletedSession(in: root)
        controls.update(isRecording: false, session: latestSession)

        notesWindow.viewModel.onCommand = { [weak self] command in
            self?.handleNotes(command)
        }
        briefWindow.onRegenerate = { [weak self] in self?.generateBrief() }
        briefWindow.onCancel = { [weak self] in self?.cancelBrief() }
        briefWindow.onReveal = { [weak self] in self?.revealBriefSession() }
        briefWindow.onShowEvidence = { [weak self] references in self?.showEvidence(references) }
        providerSetup.onSaveConfiguration = { [weak self] configuration in
            self?.saveProvider(configuration)
        }
        providerSetup.onCheckReadiness = { [weak self] configuration in
            self?.checkProviderReadiness(configuration)
        }

        let transcriptionReference = AppControllerReference(self)
        Task { [transcription, root, transcriptionReference] in
            await transcription.setStatusHandler { status in
                Task { @MainActor in
                    transcriptionReference.value?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }

        // Only durable markers from a previous *explicit* generation request
        // are resumed. A directory with merely a transcript is never queued.
        resumeExplicitBriefsIfConfigured()
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        NSApp.terminate(nil)
    }

    func showControls() { controls.show() }

    /// A Dock click is a reopen request when Quill has no visible windows.
    /// Bring the existing controls window forward instead of doing nothing.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        controls.show()
        return true
    }

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
            bindLiveNotes(to: newSession)
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
        latestSession = dir
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
        guard let latestSession = latestSession ?? Self.latestCompletedSession(in: root) else { return }
        self.latestSession = latestSession
        NSWorkspace.shared.open(latestSession)
    }

    private func bindLiveNotes(to recording: RecordingSession) {
        let directory = recording.dir
        let identity = recording.sessionID
        let startedAt = recording.startedAt
        Task { [weak self] in
            do {
                let store = try SessionNoteStore(sessionDirectory: directory, sessionID: identity)
                let snapshot = await store.snapshot()
                await MainActor.run {
                    guard self?.session?.dir == directory else { return }
                    self?.noteStore = store
                    self?.noteSessionID = identity
                    self?.noteSessionStartedAt = startedAt
                    self?.notesWindow.viewModel.bind(sessionID: identity, snapshot: snapshot)
                }
            } catch {
                await MainActor.run {
                    self?.notesWindow.viewModel.setSaveState(.failed(message: "Could not open local notes: \(error)"))
                }
            }
        }
    }

    private func openNotes() {
        if session == nil, let directory = latestSession ?? Self.latestCompletedSession(in: root) {
            bindCompletedNotes(to: directory)
        }
        notesWindow.show()
    }

    private func bindCompletedNotes(to directory: URL) {
        guard noteStore == nil || noteSessionID == nil || session?.dir != directory else { return }
        Task { [weak self] in
            do {
                let store = try SessionNoteStore(sessionDirectory: directory)
                let snapshot = await store.snapshot()
                await MainActor.run {
                    guard self?.session == nil else { return }
                    self?.latestSession = directory
                    self?.noteStore = store
                    self?.noteSessionID = snapshot.sessionID
                    self?.noteSessionStartedAt = Self.startedAt(in: directory)
                    self?.notesWindow.viewModel.bind(sessionID: snapshot.sessionID, snapshot: snapshot)
                }
            } catch {
                await MainActor.run {
                    self?.notesWindow.viewModel.setSaveState(.failed(message: "Could not open local notes: \(error)"))
                }
            }
        }
    }

    private func handleNotes(_ command: MeetingNotesCommand) {
        guard let store = noteStore, let sessionID = noteSessionID else { return }
        let commandSessionID: String = switch command {
        case let .selectTemplate(id, _), let .saveNote(id, _, _), let .deleteNote(id, _), let .requestTimestampMarker(id): id
        }
        guard commandSessionID == sessionID else { return }
        let capturedAtMS = meetingRelativeMilliseconds()
        let marker = timestampMarker()
        Task { [weak self] in
            do {
                let snapshot: RawMeetingNotes
                switch command {
                case let .selectTemplate(_, template):
                    try await store.setTemplate(template)
                    snapshot = await store.snapshot()
                case let .saveNote(_, noteID, text):
                    if let noteID {
                        try await store.update(id: noteID, text: text)
                    } else {
                        try await store.add(text: text, capturedAtMS: capturedAtMS)
                    }
                    snapshot = await store.snapshot()
                case let .deleteNote(_, noteID):
                    try await store.delete(id: noteID)
                    snapshot = await store.snapshot()
                case .requestTimestampMarker:
                    self?.notesWindow.viewModel.insertTimestampMarker(marker)
                    return
                }
                _ = self?.notesWindow.viewModel.accept(snapshot: snapshot)
            } catch {
                self?.notesWindow.viewModel.setSaveState(.failed(message: "Could not save locally: \(error)"))
            }
        }
    }

    private func meetingRelativeMilliseconds() -> Int {
        guard let startedAt = noteSessionStartedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }

    private func timestampMarker() -> String {
        "[\(Self.format(TimeInterval(meetingRelativeMilliseconds()) / 1_000))]"
    }

    private func openBrief() {
        guard let directory = latestSession ?? Self.latestCompletedSession(in: root) else {
            briefViewModel.update(state: .missing, rawNotes: nil, sessionDirectory: nil)
            briefWindow.show()
            return
        }
        latestSession = directory
        refreshBriefPresentation(for: directory)
        briefWindow.show()
    }

    private func refreshBriefPresentation(for directory: URL) {
        Task { [weak self] in
            let rawNotes = try? await SessionNoteStore(sessionDirectory: directory).snapshot()
            let state: MeetingBriefViewModel.State
            let briefURL = MeetingBriefStore(sessionDirectory: directory).briefURL
            if let data = try? Data(contentsOf: briefURL), let brief = try? JSONDecoder().decode(MeetingBrief.self, from: data) {
                state = .ready(brief)
            } else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.json").path) {
                state = .missing
            } else {
                state = .failed(message: "Transcript is not ready yet. Generate a brief only after transcription completes.")
            }
            await MainActor.run {
                self?.briefViewModel.update(state: state, rawNotes: rawNotes, sessionDirectory: directory)
            }
        }
    }

    private func generateBrief() {
        guard let directory = latestSession ?? Self.latestCompletedSession(in: root) else {
            briefViewModel.updateState(.failed(message: "Choose a completed transcript first."))
            return
        }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.json").path) else {
            briefViewModel.updateState(.failed(message: "Transcript is not ready yet. Brief generation never reads audio."))
            return
        }
        let provider = Config.lmStudioProvider()
        guard provider.isEnabled else {
            briefViewModel.updateState(.failed(message: "Enable and save the local LM Studio provider in Brief provider setup first."))
            return
        }
        do {
            let configuration = try Config.lmStudioConfiguration(provider: provider)
            let coordinator = PostMeetingCoordinator(engine: LMStudioSummarizationEngine(configuration: configuration))
            briefCoordinator = coordinator
            let reference = AppControllerReference(self)
            Task {
                await coordinator.setStatusHandler { state in
                    Task { @MainActor in reference.value?.showBriefStatus(state, directory: directory) }
                }
                do {
                    try await coordinator.enqueue(directory)
                } catch {
                    await MainActor.run { reference.value?.briefViewModel.updateState(.failed(message: "\(error)")) }
                }
            }
        } catch {
            briefViewModel.updateState(.failed(message: "Invalid local provider setup: \(error)"))
        }
    }

    private func showBriefStatus(_ state: PostMeetingCoordinator.State, directory: URL) {
        switch state {
        case .idle: break
        case let .preparing(_, queued):
            briefViewModel.updateState(.processing(message: queued > 0 ? "Preparing locally; \(queued) waiting." : "Preparing frozen local inputs."))
        case let .generating(_, queued):
            briefViewModel.updateState(.processing(message: queued > 0 ? "Generating locally; \(queued) waiting." : "Generating from transcript and notes only."))
        case .ready:
            refreshBriefPresentation(for: directory)
        case let .failed(_, message):
            briefViewModel.updateState(.failed(message: message))
        case .cancelled:
            briefViewModel.updateState(.missing)
        }
    }

    private func cancelBrief() {
        guard let directory = briefViewModel.sessionDirectory, let coordinator = briefCoordinator else { return }
        Task { _ = await coordinator.cancel(directory) }
    }

    private func revealBriefSession() {
        guard let directory = briefViewModel.sessionDirectory else { return }
        NSWorkspace.shared.open(directory)
    }

    private func showEvidence(_ references: [EvidenceReference]) {
        guard !references.isEmpty, let directory = briefViewModel.sessionDirectory else { return }
        NSWorkspace.shared.open(directory.appendingPathComponent("transcript.json"))
    }

    private func saveProvider(_ provider: LMStudioProviderConfiguration) {
        do {
            try Config.saveLMStudioProvider(provider)
            providerSetup.update(readiness: provider.isEnabled ? .unavailable(.providerUnavailable("Saved. Check availability when LM Studio is running locally.")) : .disabled)
        } catch {
            providerSetup.update(readiness: .unavailable(.invalidConfiguration("Could not save local provider settings: \(error)")))
        }
    }

    private func checkProviderReadiness(_ provider: LMStudioProviderConfiguration) {
        Task { [weak self] in
            do {
                let readiness = try await LMStudioProviderReadinessService(client: LoopbackModelsHTTPClient()).check(provider)
                await MainActor.run { self?.providerSetup.update(readiness: readiness) }
            } catch {
                await MainActor.run {
                    self?.providerSetup.update(readiness: .unavailable(.providerUnavailable("Could not check local provider: \(error)")))
                }
            }
        }
    }

    private func resumeExplicitBriefsIfConfigured() {
        let provider = Config.lmStudioProvider()
        guard provider.isEnabled, let configuration = try? Config.lmStudioConfiguration(provider: provider) else { return }
        let coordinator = PostMeetingCoordinator(engine: LMStudioSummarizationEngine(configuration: configuration))
        briefCoordinator = coordinator
        Task { await coordinator.resumePending(root: root) }
    }

    private static func latestCompletedSession(in root: URL) -> URL? {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        return entries.filter {
            manager.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }

    private static func startedAt(in directory: URL) -> Date? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["started"] as? String
        else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

private final class AppControllerReference: @unchecked Sendable {
    weak var value: AppController?

    init(_ value: AppController) {
        self.value = value
    }
}
