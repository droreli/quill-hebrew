import AppKit
import ArgumentParser
import CryptoKit
import Foundation

@main
struct Quill: ParsableCommand {
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
        // The synchronous command root enters AppKit from the process main
        // thread. `app.run()` must not be held inside a MainActor async job,
        // because that would prevent note/transcription tasks from resuming.
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
        app.mainMenu = quillMainMenu()

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

/// Quill normally lives in the menu bar, but it is still a regular AppKit app.
/// Supplying the app menu gives Command-Q the standard responder-chain route
/// to `NSApplication.terminate(_:)`, including when Controls is not key.
@MainActor
func quillMainMenu() -> NSMenu {
    let mainMenu = NSMenu(title: "Main Menu")
    let applicationItem = NSMenuItem(title: "Quill", action: nil, keyEquivalent: "")
    let applicationMenu = NSMenu(title: "Quill")
    let quit = NSMenuItem(
        title: "Quit Quill",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    // A menu item with a nil target can be swallowed by the first responder
    // when Quill has a controls field focused. Route the keyboard equivalent
    // straight to AppKit's termination action instead.
    quit.target = NSApplication.shared
    quit.keyEquivalentModifierMask = .command
    applicationMenu.addItem(quit)
    applicationItem.submenu = applicationMenu
    mainMenu.addItem(applicationItem)
    return mainMenu
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
struct Brief: ParsableCommand, Sendable {
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

    func run() throws {
        let sessionDirectory = sessionDirectory
        let enable = enable
        let endpoint = endpoint
        let model = model
        try BlockingAsyncCommand.run {
            try await Self.generateBrief(
                sessionDirectory: sessionDirectory,
                enable: enable,
                endpoint: endpoint,
                model: model
            )
        }
    }

    private static func generateBrief(
        sessionDirectory: String,
        enable: Bool,
        endpoint: String?,
        model: String?
    ) async throws {
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

/// Bridges the one async CLI subcommand into ArgumentParser's synchronous root
/// without sharing mutable task state. The app subcommand can therefore enter
/// NSApplication's event loop directly on the main thread.
private enum BlockingAsyncCommand {
    static func run(
        _ operation: @escaping @Sendable () async throws -> Void
    ) throws {
        let completion = Completion()
        Task.detached {
            do {
                try await operation()
                completion.finish(.success)
            } catch {
                completion.finish(.failure(error))
            }
        }
        try completion.wait()
    }

    private final class Completion: @unchecked Sendable {
        enum Outcome {
            case success
            case failure(any Error)
        }

        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var outcome: Outcome?

        func finish(_ outcome: Outcome) {
            lock.lock()
            self.outcome = outcome
            lock.unlock()
            semaphore.signal()
        }

        func wait() throws {
            semaphore.wait()
            lock.lock()
            let outcome = self.outcome
            lock.unlock()
            switch outcome {
            case .success: return
            case let .failure(error): throw error
            case nil: fatalError("Async command completed without an outcome")
            }
        }
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
    /// A user-selected completed session. It is intentionally distinct from
    /// `latestSession`, which is only recording lifecycle bookkeeping.
    private var selectedSession: URL?
    private var ticker: Timer?
    private lazy var notesWindow = MeetingNotesWindowController()
    private lazy var briefWindow = MeetingBriefWindowController(viewModel: briefViewModel)
    private lazy var providerSetup = ProviderSetupWindowController(configuration: Config.lmStudioProvider())
    private lazy var meetingLibrary = MeetingLibraryWindowController(root: root)
    private var hasOpenedMeetingLibrary = false
    private let briefViewModel = MeetingBriefViewModel()
    private var noteStore: SessionNoteStore?
    private var noteSessionID: String?
    private var noteSessionDirectory: URL?
    private var noteSessionStartedAt: Date?
    private var noteSessionEndedAt: Date?
    private var lastTranscriptionStatus: TranscriptionCoordinator.Status = .idle
    private var padStatusGeneration = 0
    private var isShuttingDown = false
    /// One coordinator lives for the entire application process.  In
    /// particular, reopening the brief window, retrying, or resuming a durable
    /// job never replaces an in-flight queue with a new coordinator.
    private let briefEngine: ReconfigurableBriefEngine
    private let briefCoordinator: BriefCoordinatorOwner

    init(root: URL, options: RecordingOptions) {
        self.root = root
        self.options = options
        self.transcription = TranscriptionCoordinator()
        self.controls = ControlsWindowController(root: root, options: options)
        let briefEngine = ReconfigurableBriefEngine(provider: Config.lmStudioProvider())
        self.briefEngine = briefEngine
        self.briefCoordinator = BriefCoordinatorOwner(engine: briefEngine)
        self.globalRecordHotKey = nil
        super.init()
        globalRecordHotKey = GlobalHotKey.recordingToggle { [weak self] in
            self?.toggle()
        }
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenControls = { [weak self] in self?.controls.show() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onOpenLibrary = { [weak self] in self?.openMeetingLibrary() }
        menuBar.onOpenNotes = { [weak self] in self?.openNotes() }
        menuBar.onOpenBrief = { [weak self] in self?.openBrief() }
        menuBar.onOpenBriefSession = { [weak self] directory in self?.openBrief(for: directory) }
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
        controls.onOpenLibrary = { [weak self] in self?.openMeetingLibrary() }
        controls.onOpenSession = { [weak self] in self?.openLatestSession() }
        controls.onOpenNotes = { [weak self] in self?.openNotes() }
        controls.onOpenBrief = { [weak self] in self?.openBrief() }
        controls.onOpenProviderSetup = { [weak self] in self?.providerSetup.show() }
        latestSession = Self.latestCompletedSession(in: root)
        selectedSession = latestSession
        controls.update(isRecording: false, session: latestSession)
        refreshMeetingIntelligenceAvailability()

        notesWindow.viewModel.onCommand = { [weak self] command in
            self?.handleNotes(command)
        }
        notesWindow.onEnhance = { [weak self] action in self?.handlePadEnhancement(action) }
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
        meetingLibrary.onSelectSession = { [weak self] directory in self?.selectMeeting(directory) }
        meetingLibrary.onRevealSession = { directory in NSWorkspace.shared.open(directory) }
        meetingLibrary.onOpenListeningCopy = { url in NSWorkspace.shared.open(url) }
        meetingLibrary.onOpenNotes = { [weak self] directory in self?.openNotes(for: directory) }
        meetingLibrary.onOpenBrief = { [weak self] directory in self?.openBrief(for: directory) }

        let transcriptionReference = AppControllerReference(self)
        Task { [transcription, root, transcriptionReference] in
            await transcription.setStatusHandler { status in
                Task { @MainActor in
                    transcriptionReference.value?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }

        // Install the brief status route once, before any durable explicit
        // request is resumed. A directory with merely a transcript is never
        // queued at startup.
        let briefReference = AppControllerReference(self)
        Task { [briefCoordinator, root, briefReference] in
            await briefCoordinator.installStatusHandler { state in
                Task { @MainActor in briefReference.value?.showBriefStatus(state) }
            }
            if Config.lmStudioProvider().isEnabled {
                await briefCoordinator.resumePending(root: root)
            }
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateNow }
        isShuttingDown = true
        // This is shared by the status-item Quit command, Dock Quit, and
        // Command-Q, so an in-progress recording always receives its normal
        // stop/finalize path before the process exits.
        stopSession()
        return .terminateNow
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
            selectedSession = newSession.dir
            controls.update(isRecording: true, session: newSession.dir)
            bindLiveNotes(to: newSession)
            refreshMeetingIntelligenceAvailability()
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
        noteSessionEndedAt = Self.sessionTiming(in: dir)?.ended ?? Date()
        latestSession = dir
        selectedSession = dir
        controls.update(isRecording: false, session: dir)
        refreshMeetingIntelligenceAvailability()
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        lastTranscriptionStatus = status
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
        refreshMeetingIntelligenceAvailability()
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

    private func openMeetingLibrary() {
        hasOpenedMeetingLibrary = true
        meetingLibrary.updateRecordingState(session != nil)
        meetingLibrary.show(selected: selectedSession ?? latestSession)
    }

    private func selectMeeting(_ directory: URL) {
        selectedSession = directory
        refreshMeetingIntelligenceAvailability()
    }

    private func bindLiveNotes(to recording: RecordingSession) {
        let directory = recording.dir
        let identity = recording.sessionID
        let startedAt = recording.startedAt
        // Commands are disabled while the asynchronous store opens. This
        // prevents a visible previous session from receiving a command meant
        // for this one, and makes the waiting state explicit in the UI.
        noteStore = nil
        noteSessionID = nil
        noteSessionDirectory = nil
        noteSessionStartedAt = nil
        noteSessionEndedAt = nil
        notesWindow.viewModel.unbind()
        do {
            let store = try SessionNoteStore(sessionDirectory: directory, sessionID: identity)
            noteStore = store
            noteSessionID = identity
            noteSessionDirectory = directory
            noteSessionStartedAt = startedAt
            noteSessionEndedAt = nil
            notesWindow.viewModel.bind(sessionID: identity, clock: meetingClock())
            refreshMeetingPadStatus()
            Task { [weak self] in
                let snapshot = await store.snapshot()
                await MainActor.run {
                    guard self?.session?.dir == directory else { return }
                    _ = self?.notesWindow.viewModel.accept(snapshot: snapshot)
                }
            }
        } catch {
            FileHandle.standardError.write(Data(
                "meeting notes bind failed for \(directory.lastPathComponent): \(error)\n".utf8
            ))
            notesWindow.viewModel.setSaveState(.failed(message: "Could not open local notes: \(error)"))
        }
    }

    private func openNotes(for requestedDirectory: URL? = nil) {
        if let requestedDirectory { selectMeeting(requestedDirectory) }
        if let session {
            if noteStore == nil { bindLiveNotes(to: session) }
        } else if let directory = requestedDirectory ?? selectedSession ?? latestSession ?? Self.latestCompletedSession(in: root) {
            bindCompletedNotes(to: directory)
        }
        notesWindow.show()
    }

    private func bindCompletedNotes(to directory: URL) {
        guard noteStore == nil || noteSessionID == nil || session?.dir != directory else { return }
        noteStore = nil
        noteSessionID = nil
        noteSessionDirectory = nil
        noteSessionStartedAt = nil
        noteSessionEndedAt = nil
        notesWindow.viewModel.unbind()
        Task { [weak self] in
            do {
                let store = try SessionNoteStore(sessionDirectory: directory)
                let snapshot = await store.snapshot()
                await MainActor.run {
                    guard self?.session == nil else { return }
                    self?.latestSession = directory
                    guard let self else { return }
                    self.noteStore = store
                    self.noteSessionID = snapshot.sessionID
                    self.noteSessionDirectory = directory
                    let timing = Self.sessionTiming(in: directory)
                    self.noteSessionStartedAt = timing?.started
                    self.noteSessionEndedAt = timing?.ended
                    self.notesWindow.viewModel.bind(sessionID: snapshot.sessionID, snapshot: snapshot, clock: self.meetingClock())
                    self.refreshMeetingPadStatus()
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
        case let .selectTemplate(id, _), let .saveNote(id, _, _, _), let .deleteNote(id, _), let .requestTimestampMarker(id): id
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
                case let .saveNote(_, noteID, text, draftCapturedAtMS):
                    if let noteID {
                        try await store.update(id: noteID, text: text)
                    } else {
                        try await store.add(text: text, capturedAtMS: draftCapturedAtMS ?? capturedAtMS)
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
        let effectiveEnd = noteSessionEndedAt ?? Date()
        return max(0, Int(effectiveEnd.timeIntervalSince(startedAt) * 1_000))
    }

    private func timestampMarker() -> String {
        "[\(Self.format(TimeInterval(meetingRelativeMilliseconds()) / 1_000))]"
    }

    private func meetingClock() -> () -> Int {
        { [weak self] in self?.meetingRelativeMilliseconds() ?? 0 }
    }

    /// Resolve the pad from durable local facts only. The canonical transcript
    /// is decoded off the main actor; neither this flow nor the pad reads audio.
    private func refreshMeetingPadStatus() {
        guard let directory = noteSessionDirectory,
              let sessionID = noteSessionID,
              notesWindow.viewModel.isBound
        else {
            notesWindow.viewModel.setStatus(.unbound)
            return
        }
        padStatusGeneration += 1
        let generation = padStatusGeneration
        let fileManager = FileManager.default
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        let transcriptExists = fileManager.fileExists(atPath: transcriptURL.path)
        var facts = MeetingPadStatus.Facts(
            sessionName: directory.lastPathComponent,
            isRecording: session?.dir == directory,
            startedAt: noteSessionStartedAt,
            hasCompletedMeta: fileManager.fileExists(atPath: directory.appendingPathComponent("meta.json").path),
            transcriptSegmentCount: nil,
            transcriptionActivity: Self.padActivity(lastTranscriptionStatus),
            transcriptionEnabled: Config.transcriptionEnabled(),
            providerEnabled: Config.lmStudioProvider().isEnabled,
            briefExists: fileManager.fileExists(atPath: MeetingBriefStore(sessionDirectory: directory).briefURL.path)
        )
        guard transcriptExists else {
            notesWindow.viewModel.acceptTranscript(nil, sessionID: sessionID)
            notesWindow.viewModel.setStatus(.resolve(facts))
            return
        }
        if let cached = notesWindow.viewModel.transcript {
            facts.transcriptSegmentCount = cached.segments.count
            notesWindow.viewModel.setStatus(.resolve(facts))
            return
        }
        notesWindow.viewModel.setStatus(.resolve(facts))
        Task { [weak self] in
            let transcript = await Self.loadTranscript(at: transcriptURL)
            guard let self, self.padStatusGeneration == generation, self.noteSessionDirectory == directory else { return }
            guard let transcript else {
                facts.transcriptSegmentCount = nil
                facts.transcriptionActivity = .failed(session: directory.lastPathComponent)
                self.notesWindow.viewModel.setStatus(.resolve(facts))
                return
            }
            facts.transcriptSegmentCount = transcript.segments.count
            self.notesWindow.viewModel.acceptTranscript(transcript, sessionID: sessionID)
            self.notesWindow.viewModel.setStatus(.resolve(facts))
        }
    }

    nonisolated private static func loadTranscript(at url: URL) async -> SessionTranscript? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionTranscript.self, from: data)
    }

    private static func padActivity(_ status: TranscriptionCoordinator.Status) -> MeetingPadStatus.TranscriptionActivity {
        switch status {
        case .idle: .idle
        case let .transcribing(session, queued): .transcribing(session: session, queued: queued)
        case let .failed(session): .failed(session: session)
        }
    }

    private func handlePadEnhancement(_ action: MeetingEnhancementAvailability.Action) {
        switch action {
        case .none:
            refreshMeetingPadStatus()
        case .openProviderSetup:
            providerSetup.show()
        case .generateBrief:
            guard session == nil, let directory = noteSessionDirectory else {
                refreshMeetingPadStatus()
                return
            }
            latestSession = directory
            refreshBriefPresentation(for: directory)
            briefWindow.show()
            generateBrief()
        case .openBrief:
            guard let directory = noteSessionDirectory else { return }
            latestSession = directory
            openBrief(for: directory)
        }
    }

    private func openBrief(for requestedDirectory: URL? = nil) {
        guard session == nil else {
            refreshMeetingIntelligenceAvailability()
            return
        }
        guard let directory = requestedDirectory ?? selectedSession ?? latestSession ?? Self.latestCompletedSession(in: root) else {
            briefViewModel.update(state: .missing, rawNotes: nil, sessionDirectory: nil)
            briefWindow.show()
            return
        }
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("transcript.json").path
        ) else {
            refreshMeetingIntelligenceAvailability()
            return
        }
        selectMeeting(directory)
        refreshBriefPresentation(for: directory)
        briefWindow.show()
    }

    private func generateBrief() {
        guard session == nil else {
            briefViewModel.updateState(.failed(message: "Stop recording and wait for transcription before generating an AI brief."))
            return
        }
        guard let directory = briefViewModel.sessionDirectory ?? latestSession ?? Self.latestCompletedSession(in: root) else {
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
            _ = try Config.lmStudioConfiguration(provider: provider)
            Task { [briefEngine, briefCoordinator] in
                await briefEngine.reconfigure(provider: provider)
                do {
                    try await briefCoordinator.enqueue(directory)
                } catch {
                    await MainActor.run { [weak self] in
                        self?.briefViewModel.updateState(.failed(message: "\(error)"))
                    }
                }
            }
        } catch {
            briefViewModel.updateState(.failed(message: "Invalid local provider setup: \(error)"))
        }
    }

    private func showBriefStatus(_ state: PostMeetingCoordinator.State) {
        let directory = briefSessionDirectory(for: state)
        switch state {
        case .idle: break
        case let .preparing(_, queued):
            briefViewModel.updateState(.processing(message: queued > 0 ? "Preparing locally; \(queued) waiting." : "Preparing frozen local inputs."))
        case let .generating(_, queued):
            briefViewModel.updateState(.processing(message: queued > 0 ? "Generating locally; \(queued) waiting." : "Generating from transcript and notes only."))
        case let .ready(_, stale):
            if let directory { refreshBriefPresentation(for: directory, coordinatorReportedStale: stale) }
            refreshMeetingPadStatus()
        case let .failed(_, message):
            briefViewModel.updateState(.failed(message: message))
        case .cancelled:
            if let directory { refreshBriefPresentation(for: directory) }
            else { briefViewModel.updateState(.missing) }
        }
    }

    private func cancelBrief() {
        guard let directory = briefViewModel.sessionDirectory else { return }
        Task { [briefCoordinator] in _ = await briefCoordinator.cancel(directory) }
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
            Task { [briefEngine] in await briefEngine.reconfigure(provider: provider) }
            providerSetup.update(readiness: provider.isEnabled ? .unavailable(.providerUnavailable("Saved. Check availability when LM Studio is running locally.")) : .disabled)
            refreshMeetingPadStatus()
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

    private func refreshMeetingIntelligenceAvailability() {
        let directory = session?.dir ?? selectedSession ?? latestSession ?? Self.latestCompletedSession(in: root)
        let transcriptReady = directory.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
        } ?? false
        let availability = MeetingBriefAvailability(
            isRecording: session != nil,
            transcriptReady: transcriptReady
        )
        menuBar.updateBriefSessions(
            CompletedTranscriptSessions.directories(in: root),
            selected: selectedSession
        )
        menuBar.updateBriefAvailability(availability)
        controls.updateMeetingIntelligence(isRecording: session != nil, session: directory)
        if hasOpenedMeetingLibrary, meetingLibrary.isVisible {
            meetingLibrary.updateRecordingState(session != nil)
            meetingLibrary.refresh(selected: selectedSession)
        }
        refreshMeetingPadStatus()
    }

    private static func latestCompletedSession(in root: URL) -> URL? {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        return entries.filter {
            manager.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }

    private func briefSessionDirectory(for state: PostMeetingCoordinator.State) -> URL? {
        let name: String? = switch state {
        case .idle: nil
        case let .preparing(session, _), let .generating(session, _), let .ready(session, _), let .failed(session, _), let .cancelled(session): session
        }
        guard let name else { return nil }
        if briefViewModel.sessionDirectory?.lastPathComponent == name { return briefViewModel.sessionDirectory }
        if latestSession?.lastPathComponent == name { return latestSession }
        return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent == name })
    }

    private func refreshBriefPresentation(
        for directory: URL,
        coordinatorReportedStale: Bool = false
    ) {
        Task { [weak self] in
            let rawNotes = try? await SessionNoteStore(sessionDirectory: directory).snapshot()
            let state: MeetingBriefViewModel.State
            let briefURL = MeetingBriefStore(sessionDirectory: directory).briefURL
            if let data = try? Data(contentsOf: briefURL), let brief = try? JSONDecoder().decode(MeetingBrief.self, from: data) {
                state = meetingBriefPresentationState(
                    brief: brief,
                    sessionDirectory: directory,
                    rawNotes: rawNotes,
                    coordinatorReportedStale: coordinatorReportedStale
                )
            } else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.json").path) {
                state = .missing
            } else {
                state = .failed(message: "Transcript is not ready yet. Generate a brief only after transcription completes.")
            }
            await MainActor.run {
                self?.briefViewModel.update(state: state, rawNotes: rawNotes, sessionDirectory: directory)
                guard let self else { return }
                self.menuBar.updateBriefSessions(
                    CompletedTranscriptSessions.directories(in: self.root),
                    selected: directory
                )
            }
        }
    }

    private static func sessionTiming(in directory: URL) -> (started: Date?, ended: Date?)? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let formatter = ISO8601DateFormatter()
        return (
            (object["started"] as? String).flatMap(formatter.date(from:)),
            (object["ended"] as? String).flatMap(formatter.date(from:))
        )
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

/// Converts durable artifact provenance into the viewer state. Keeping this
/// small decision point outside AppKit makes stale-input behavior testable
/// without starting a recorder or constructing `AppController`.
@MainActor
func meetingBriefPresentationState(
    brief: MeetingBrief,
    sessionDirectory: URL,
    rawNotes: RawMeetingNotes?,
    coordinatorReportedStale: Bool = false
) -> MeetingBriefViewModel.State {
    if coordinatorReportedStale || currentBriefInputsAreStale(
        brief: brief,
        sessionDirectory: sessionDirectory,
        rawNotes: rawNotes
    ) {
        return .stale(brief)
    }
    return .ready(brief)
}

private func currentBriefInputsAreStale(
    brief: MeetingBrief,
    sessionDirectory: URL,
    rawNotes: RawMeetingNotes?
) -> Bool {
    guard let transcriptData = try? Data(contentsOf: sessionDirectory.appendingPathComponent("transcript.json")),
          sha256(transcriptData) == brief.inputs.transcriptSHA256,
          let rawNotes,
          rawNotes.revision == brief.inputs.rawNotesRevision
    else { return true }
    // Legacy artifacts have no raw-note digest. Their recorded revision is the
    // only available comparison; current artifacts always use the digest.
    guard let expectedDigest = brief.inputs.rawNotesSHA256 else { return false }
    return (try? sortedRawNotesDigest(rawNotes)) != expectedDigest
}

private func sortedRawNotesDigest(_ rawNotes: RawMeetingNotes) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return sha256(try encoder.encode(rawNotes))
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A stable routing layer lets one application-owned coordinator retain its
/// durable queue while the user changes the optional provider settings. Each
/// invocation snapshots the provider and finishes with that configuration;
/// later saves apply only to subsequent jobs.
actor ReconfigurableBriefEngine: SummarizationEngine {
    private var provider: LMStudioProviderConfiguration

    init(provider: LMStudioProviderConfiguration) {
        self.provider = provider
    }

    func reconfigure(provider: LMStudioProviderConfiguration) {
        self.provider = provider
    }

    func summarize(
        transcript: SessionTranscript,
        rawNotes: RawMeetingNotes,
        input: SummaryInput
    ) async throws -> MeetingBrief {
        let configuration = try Config.lmStudioConfiguration(provider: provider)
        let engine = LMStudioSummarizationEngine(configuration: configuration)
        return try await engine.summarize(transcript: transcript, rawNotes: rawNotes, input: input)
    }
}

/// The narrow, testable owner for the one coordinator used by `AppController`.
/// It intentionally permits its status route to be installed just once: a
/// second brief window or a provider save cannot detach resumed-job updates.
actor BriefCoordinatorOwner {
    private let coordinator: PostMeetingCoordinator
    private var hasStatusHandler = false

    init(engine: any SummarizationEngine) {
        coordinator = PostMeetingCoordinator(engine: engine)
    }

    func installStatusHandler(_ handler: @escaping @Sendable (PostMeetingCoordinator.State) -> Void) async {
        guard !hasStatusHandler else { return }
        hasStatusHandler = true
        await coordinator.setStatusHandler(handler)
    }

    func enqueue(_ directory: URL) async throws {
        try await coordinator.enqueue(directory)
    }

    func cancel(_ directory: URL) async -> Bool {
        await coordinator.cancel(directory)
    }

    func resumePending(root: URL) async {
        await coordinator.resumePending(root: root)
    }
}
