# Work Packages: Quill Notes and Local Meeting Briefs

This plan is designed for parallel Terra High agents. The contracts in
`PRD_LOCAL_MEETING_NOTES.md` are frozen inputs. Packages may build against
fixtures/stubs immediately; only the final integration package touches the
existing application orchestrators.

## Parallel execution shape

```text
Contract freeze (this document + PRD)
        |
        +-- WP1 Core contracts and tests
        +-- WP2 Raw-notes persistence
        +-- WP3 Notes window
        +-- WP4 Local model adapter
        +-- WP5 Brief pipeline and store
        +-- WP6 Brief viewer
        +-- WP7 Setup and readiness UX
        +-- WP8 Privacy and user docs
                         |
                  WP9 Integration
                         |
                  WP10 Release QA
```

WP1–WP8 begin in parallel. WP1 is merged first because it materializes the
already-frozen contracts in Swift. Other packages rebase onto it; they do not
wait to start. WP9 is intentionally the only package that owns existing
orchestration files.

## Shared rules for every agent

- Model: Terra High.
- Work in a dedicated branch/worktree.
- Do not revert or rewrite another package's changes.
- Preserve `mic.caf`, `system.caf`, `mixed.m4a`, `meta.json`, and
  `transcript.json`; derived features never overwrite source artifacts.
- No cloud API, account, telemetry, `URLSession`, hidden download, or daemon.
- Use atomic file writes and versioned schemas.
- Do not start a real recording during automated verification.
- Each package ends with `swift build`, focused tests, and `git diff --check`.
- Existing orchestration files are reserved for WP9 unless a package explicitly
  owns one below.

## WP1 — Contracts and test harness

**Purpose:** encode the frozen schemas and give every parallel package a stable
Swift API.

**Owned files**

- `Package.swift`
- `Sources/quill/MeetingIntelligence/Contracts.swift`
- `Sources/quill/MeetingIntelligence/TranscriptReader.swift`
- `Tests/QuillCoreTests/**`
- `Tests/Fixtures/**`

**Outputs**

- Shared `SessionTranscript`, `TranscriptSegment`, `RawMeetingNotes`,
  `MeetingBrief`, `BriefItem`, `ActionItem`, `EvidenceReference`,
  `GenerationProvenance`, and `SummaryInput` models.
- `SummarizationEngine: Sendable` protocol.
- Stable segment-ID derivation for old transcripts.
- A Swift test target and Hebrew/English/mixed fixtures.

**Acceptance**

- Decode a current real-shape `transcript.json` fixture.
- Round-trip raw notes and a meeting brief without loss.
- Reject unsupported schema versions, negative/out-of-order ranges, duplicate
  note IDs, and evidence IDs absent from the transcript.
- Existing executable and release build still compile.

**Dependencies:** frozen PRD only.  
**No touch:** `Quill.swift`, UI, Audio, RecordingSession, Config, transcription
engines/coordinator.

## WP2 — Raw-notes persistence

**Purpose:** provide crash-safe per-session notes without involving UI or AI.

**Owned files**

- `Sources/quill/MeetingIntelligence/SessionNoteStore.swift`
- `Sources/quill/MeetingIntelligence/SessionIdentity.swift`
- focused tests under `Tests/QuillCoreTests/Notes/**`

**Outputs**

- `SessionNoteStore` actor as the sole writer of `raw-notes.json`.
- Atomic snapshots, monotonically increasing revision, 500 ms maximum debounce,
  add/update/delete methods, and read-only snapshot API.
- Backward-compatible session identity helper for folders lacking `session_id`.

**Acceptance**

- Concurrent edits serialize correctly and revisions never go backward.
- Crash/interrupted-write fixture leaves the last valid snapshot readable.
- Note timestamps are meeting-relative and non-negative.
- Saving notes does not modify any source file hash.

**Dependencies:** WP1 API; may start with local contract stubs.  
**No touch:** existing source files, UI, audio, transcription, model code.

## WP3 — Native in-meeting Notes window

**Purpose:** deliver the keyboard-first note-taking experience independently of
recording orchestration.

**Owned files**

- `Sources/quill/UI/MeetingNotesWindowController.swift`
- `Sources/quill/UI/MeetingNotesViewModel.swift`
- UI-focused fixtures/tests if practical

**Outputs**

- Native AppKit Notes window with template selector, note editor/list,
  add-time-marker action, visible save state, and local/private indicator.
- Callback-only API: bind/unbind session, emit note commands, accept snapshots.
- Natural RTL/LTR content, VoiceOver labels, keyboard focus order, and safe
  empty/error states.

**Acceptance**

- Hebrew, English, and mixed notes render correctly.
- Closing/reopening the window preserves the bound view model.
- The window contains no start/stop implementation and cannot capture audio.
- No synchronous disk work occurs on the main actor.

**Dependencies:** WP1 view models only; use fixtures until WP2 is merged.  
**No touch:** `ControlsWindowController.swift`, `MenuBarController.swift`,
`Quill.swift`, recording/transcription code.

## WP4 — Embedded local model adapter

**Purpose:** implement the richer fully local summarization engine behind the
shared protocol.

**Owned files**

- new MLX package entries in `Package.swift` after coordinating with WP1
- `Sources/quill/MeetingIntelligence/MLXSummarizationEngine.swift`
- `Sources/quill/MeetingIntelligence/PromptBuilder.swift`
- `Sources/quill/MeetingIntelligence/GuidedBriefDecoder.swift`
- focused model-adapter tests and fakes

**Outputs**

- Embedded MLX Swift engine with pinned local model provenance.
- Segment-boundary chunking, constrained JSON extraction/reduction, timeout,
  cancellation, output cap, and release.
- Strict validation: the model emits only allowed segment IDs; Quill enriches
  evidence and rejects unsupported claims.
- A fake deterministic engine for unit/integration tests.

**Acceptance**

- Fake-engine tests cover malformed JSON, unknown IDs, cancellation, timeout,
  mixed language, and long-meeting chunk/reduce.
- Generation code contains no network client or downloader.
- Missing weights fail with `model_not_installed`; failed integrity fails with
  `model_integrity_failed`; neither falls back to cloud.
- Model release returns GPU resources before another queued job.

**Dependencies:** WP1 protocol; starts with a local copy of the frozen contract.  
**No touch:** audio, transcription engines, `TranscriptionCoordinator.swift`,
UI, `Quill.swift`, existing Hebrew installer.

## WP5 — Brief pipeline and persistence

**Purpose:** make generation durable, recoverable, and independent of the
transcription queue.

**Owned files**

- `Sources/quill/MeetingIntelligence/PostMeetingCoordinator.swift`
- `Sources/quill/MeetingIntelligence/MeetingBriefStore.swift`
- `Sources/quill/MeetingIntelligence/BriefMarkdownRenderer.swift`
- focused persistence/pipeline tests

**Outputs**

- Explicit local job queue with `idle/preparing/generating/ready/failed/cancelled`.
- One atomic snapshot of transcript + raw-note revision per job.
- SHA-256 input provenance, staleness detection, cancellation/retry, atomic JSON
  and Markdown writes, and restart discovery of explicit incomplete jobs.
- Engine injection so WP4 and deterministic fixtures share the same pipeline.

**Acceptance**

- Interrupted generation leaves the last valid brief intact.
- Editing notes during generation marks the result stale without corrupting it.
- Raw tracks, metadata, transcript, and raw notes remain hash-identical.
- One failed session does not block later jobs.
- Existing `on_stop` semantics remain unchanged.

**Dependencies:** WP1; uses fake engine until WP4 merges.  
**No touch:** `TranscriptionCoordinator.swift`, `RecordingSession.swift`, audio,
UI, `Quill.swift`.

## WP6 — Native meeting-brief viewer

**Purpose:** make generated output reviewable and clearly sourced.

**Owned files**

- `Sources/quill/UI/MeetingBriefWindowController.swift`
- `Sources/quill/UI/MeetingBriefViewModel.swift`
- presentation fixtures/tests

**Outputs**

- Native viewer for overview, topics, decisions, action items, questions,
  warnings, provenance, and evidence timestamps.
- Clear separation between raw user notes and AI-generated content.
- Regenerate/cancel/reveal callbacks; no pipeline implementation.
- Missing, processing, failed, stale, and ready states.

**Acceptance**

- Evidence actions resolve only known segment IDs.
- Hebrew text uses natural RTL; controls use system direction.
- VoiceOver exposes section names, evidence labels, progress, and errors.
- The viewer cannot modify source transcript or audio.

**Dependencies:** WP1 models; fixtures until WP5 merges.  
**No touch:** current controls/menu/app orchestrator, recording/transcription,
model/persistence files.

## WP7 — Model setup and readiness

**Purpose:** make the one-time local model boundary explicit and reversible.

**Owned files**

- `Sources/quill/MeetingIntelligence/ModelManifest.swift`
- `Sources/quill/MeetingIntelligence/ModelReadiness.swift`
- `Sources/quill/UI/ModelSetupWindowController.swift`
- `scripts/install-summary-model.sh`
- setup fixtures/tests

**Outputs**

- Manifest containing source, exact revision, SHA-256, size, license, runtime
  compatibility, and local storage path.
- Preflight for free disk, unified-memory tier, model integrity, and runtime.
- Explicit user-invoked install/remove instructions and progress UI contract.
- No invocation from normal run, recording, transcription, or generation.

**Acceptance**

- No download begins without the explicit setup command/action.
- Wrong hash or partial model is rejected and never used.
- Removal names the exact model directory and leaves recordings untouched.
- License/notice and expected disk use are shown before download.

**Dependencies:** can start from the model decision in the PRD; later connects
to WP4.  
**No touch:** existing Hebrew MLX installer, audio, transcription, app
orchestrator.

## WP8 — Privacy, consent, and user documentation

**Purpose:** define the exact public promise and setup/recovery guidance.

**Owned files**

- `PRIVACY_AND_CONSENT.md`
- `docs/LOCAL_MEETING_NOTES.md`
- additive README links only

**Outputs**

- Local-only data-flow explanation and every created artifact.
- Consent reminder language that does not claim universal legal compliance.
- Separate model-download boundary, model license/size/provenance, offline usage,
  retention, regeneration, removal, and recovery guidance.
- Explanation that system audio may include unrelated playback/notifications.

**Acceptance**

- Docs distinguish user notes, canonical transcript, and generated content.
- No claim that generated notes are factual without evidence.
- No cloud fallback, telemetry, hidden retention, or automatic sharing is
  implied.

**Dependencies:** frozen PRD; final wording reconciled after WP4/WP7.  
**No touch:** implementation files.

## WP9 — Application integration

**Purpose:** wire the independently built packages through one conflict owner.

**Sole-owned existing files**

- `Sources/quill/Quill.swift`
- `Sources/quill/RecordingSession.swift`
- `Sources/quill/Transcription/TranscriptionCoordinator.swift`
- `Sources/quill/UI/ControlsWindowController.swift`
- `Sources/quill/UI/MenuBarController.swift`
- `Sources/quill/Config.swift`
- `Sources/quill/Verification.swift`

**Outputs**

- Additive `schema_version` and `session_id` in new-session metadata.
- Bind/unbind the note store and Notes window to the active session.
- Publish transcript-ready without changing the existing transcript queue.
- `quill brief <session>` CLI and UI Generate/Regenerate actions.
- Open Notes, Open latest brief, and Meeting History menu/control actions.
- Status propagation without conflating recording, transcription, and brief jobs.
- Explicit generation only; no automatic model run in MVP.

**Acceptance**

- Notes work during recording without affecting either audio track.
- A fixture session generates/opens a brief; a real recording is not required.
- Recording can start while a brief viewer is open; generation never starts
  until transcription has released the speech engine.
- Transcription disabled/missing/failed states preserve raw notes and show a
  clear brief-blocked reason.
- `retranscribe` preserves raw notes and existing briefs, then correctly marks
  an old brief stale if the transcript digest changes.
- Launch-at-login, menu start/stop, mixed export, and current defaults retain
  their behavior.

**Dependencies:** merged WP1, WP2, WP3, WP5, WP6; WP4/WP7 may remain behind a
feature flag until their gates pass.  
**No touch:** audio internals and transcription-engine implementations.

## WP10 — Integration and release QA

**Purpose:** prove the product boundary, not just compilation.

**Owned files**

- additive integration fixtures/tests
- `docs/RELEASE_CHECKLIST_LOCAL_MEETING_NOTES.md`
- no feature implementation

**Verification matrix**

- `swift test`
- `swift build -c release`
- `quill doctor`
- `quill verify-mix`
- fixture-based `quill brief`
- network-denied generation after setup
- notes autosave + quit/reopen recovery
- incomplete/one-track/failed transcript behavior
- malformed/unknown-evidence model output
- cancellation, timeout, stale notes, and restart recovery
- source-file hash preservation
- Hebrew/English/mixed RTL and content review
- VoiceOver/keyboard/contrast review
- controls-only visual launch with no unsolicited recording
- launch-at-login regression check
- `git diff --check`

**Exit gate**

No MVP release until all high-risk privacy, evidence, raw-file-preservation, and
recording-regression checks pass. Local fixture success is not evidence of
microphone/system-audio permission state on another Mac.

## Suggested agent dispatch

After the contract commit is merged, assign one Terra High agent to each of
WP2–WP8 concurrently. Assign a separate integration owner to WP9 only after the
required packages pass their own tests. WP10 is an independent reviewer and
must not repair implementation while auditing it.

Every implementation prompt should include:

1. the frozen PRD and this package section;
2. exact file ownership and no-touch zones;
3. the shared schema/version constants;
4. instruction to preserve concurrent edits and rebase rather than revert;
5. package-specific acceptance tests and required evidence.
