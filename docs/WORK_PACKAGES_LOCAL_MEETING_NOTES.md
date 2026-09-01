# Work Packages: Quill Notes and Local Meeting Briefs

This plan is designed for parallel Terra High agents. The contracts in
`PRD_LOCAL_MEETING_NOTES.md` are frozen inputs. Packages may build against
fixtures/stubs immediately; only the final integration package touches the
existing application orchestrators.

## Parallel execution shape

```text
WP0 Product contract + test-target spine (short serial gate)
        |
        +-- WP1 Core Swift contracts
        +-- WP2 Raw-notes persistence
        +-- WP3 Notes window
        +-- WP4 LM Studio loopback provider
        +-- WP5 Brief pipeline and store
        +-- WP6 Brief viewer
        +-- WP7 Setup and readiness UX
        +-- WP8 Privacy and user docs
                         |
                  WP9 Integration
                         |
                  WP10 Release QA
```

WP0 is the only required serial gate: it creates the test target, fixtures, and
producer/consumer contract. WP1 materializes that contract in Swift. WP2–WP8
then execute in parallel against buildable shared types. WP9 is intentionally
the only package that owns existing application orchestrators.

## Shared rules for every agent

- Model: Terra High.
- Work in a dedicated branch/worktree.
- Do not revert or rewrite another package's changes.
- Preserve `mic.caf`, `system.caf`, `mixed.m4a`, `meta.json`, and
  `transcript.json`; derived features never overwrite source artifacts.
- No cloud API, account, telemetry, hidden download, or Quill-managed daemon.
  The sole network exception is WP4's opt-in loopback client, which accepts
  only `127.0.0.1`/`::1`, disables proxies, and refuses redirects.
- Use atomic file writes and versioned schemas.
- Do not start a real recording during automated verification.
- Each package ends with `swift build`, focused tests, and `git diff --check`.
- Existing orchestration files are reserved for WP9 unless a package explicitly
  owns one below.

## WP0 — Product contract and test-target spine

**Purpose:** remove the hidden dependencies identified by the independent
review before parallel implementation begins.

**Outputs**

- Freeze `raw-notes.v1`, `meeting-brief.v1`, evidence IDs, provider errors, and
  generator provenance in this PRD.
- Create a buildable Swift test target and transcript fixtures.
- Decide the producer seam for canonical transcript segments without changing
  capture or transcription behavior.

**Acceptance:** `swift test`, current release build, and fixture decoding pass.
**Dependencies:** none. This is the short serial gate.

## WP1 — Core Swift contracts

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

## WP4 — LM Studio loopback provider

**Purpose:** implement a configurable local provider behind the shared protocol
without coupling Quill to one model.

**Owned files**

- `Sources/quill/MeetingIntelligence/LMStudioSummarizationEngine.swift`
- `Sources/quill/MeetingIntelligence/LoopbackHTTPClient.swift`
- `Sources/quill/MeetingIntelligence/PromptBuilder.swift`
- `Sources/quill/MeetingIntelligence/BriefResponseDecoder.swift`
- focused model-adapter tests and fakes

**Outputs**

- OpenAI-compatible LM Studio chat-completions client using JSON-schema output.
- Configurable model ID; initial personal setting is
  `google/gemma-4-26b-a4b-qat`.
- Strict literal-loopback endpoint validation, disabled system proxies, and no
  redirects.
- Segment-boundary chunking, constrained JSON extraction/reduction, timeout,
  cancellation, output cap, and release.
- Strict validation: the model emits only allowed segment IDs; Quill enriches
  evidence and rejects unsupported claims.
- A fake deterministic engine for unit/integration tests.

**Acceptance**

- Fake-engine tests cover malformed JSON, unknown IDs, cancellation, timeout,
  mixed language, and long-meeting chunk/reduce.
- Non-loopback endpoints are rejected before a request is built.
- Server down or missing model returns `provider_unavailable`; malformed output
  and model changes fail safely without touching recording/transcription.
- No code launches, installs, downloads, or updates LM Studio.
- Standard and uncensored variants use identical Quill-side evidence validation.

**Dependencies:** WP1 protocol; starts with a local copy of the frozen contract.  
**No touch:** `Package.swift`, audio, transcription engines,
`TranscriptionCoordinator.swift`, UI, `Quill.swift`, existing Hebrew installer.

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

## WP7 — Provider setup and readiness

**Purpose:** make the one-time local model boundary explicit and reversible.

**Owned files**

- `Sources/quill/MeetingIntelligence/ProviderReadiness.swift`
- `Sources/quill/UI/ProviderSetupWindowController.swift`
- setup fixtures/tests

**Outputs**

- Opt-in provider configuration and a loopback `GET /v1/models` readiness probe.
- Display of reported model IDs plus the distinction between reported and
  checksum-verified provenance.
- Model selector and provider-unavailable guidance; no download management.
- Readiness is never probed unless provider mode is explicitly enabled.

**Acceptance**

- Provider mode is off by default and requires explicit opt-in.
- Non-loopback endpoints are rejected.
- Provider/model absence leaves recording and transcription fully operational.
- Quill does not launch, install, remove, or update LM Studio or its models.

**Dependencies:** frozen loopback/provider contract; later connects to WP4.
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
- LM Studio's updater, LAN settings, and model provenance remain outside
  Quill's trust boundary; users are told to keep LAN serving disabled.

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
- provider disabled by default; literal-loopback/proxy/redirect enforcement
- provider unavailable, model changed, and reported-provenance warnings
- fixture bake-off across Gemma 12B/26B and Qwen 27B/35B candidates
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

After WP0/WP1 are merged, assign one Terra High agent to each of WP2–WP8
concurrently. Assign a separate integration owner to WP9 only after the
required packages pass their own tests. WP10 is an independent reviewer and
must not repair implementation while auditing it.

Every implementation prompt should include:

1. the frozen PRD and this package section;
2. exact file ownership and no-touch zones;
3. the shared schema/version constants;
4. instruction to preserve concurrent edits and rebase rather than revert;
5. package-specific acceptance tests and required evidence.
