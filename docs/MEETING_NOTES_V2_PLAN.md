# Meeting Notes V2

## Goal

Make Quill's in-meeting notes a calm, time-aware local pad: quick raw notes
while recording, an honest view of transcription state, and a deliberate local
AI brief only after canonical inputs are ready. Granola is an interaction
reference, not Quill's privacy model or visual design.

## Research boundary

Fable reviewed only Granola's public website, help center, privacy, and
security material. It distinguishes verified public behaviour from inference.

Verified for Granola desktop: it transcribes in real time, uses system audio
and microphone without a meeting bot, accepts user notes during the meeting,
and uses the transcript plus raw notes for enhanced notes. Its public material
also describes cloud transcription and model providers.

Quill deliberately differs: it has no account, cloud fallback, network
telemetry, or live transcription. Quill's current `TranscriptionCoordinator`
runs after recording stops. V2 must state that fact instead of pretending that
a live transcript exists.

## Implemented P0

1. A compact, single-column pad with a lifecycle strip. It says whether Quill
   is recording, waiting, transcribing locally, failed, disabled, or has a
   ready canonical transcript.
2. A new note is stamped when the user begins writing, not when they press
   Save. Editing a note preserves its original meeting time.
3. Once `transcript.json` is present, selecting a note shows nearby canonical
   transcript lines. This is deterministic time-window lookup, never an LLM
   call and never an audio read.
4. The explicit action is availability-aware: it is disabled until the
   transcript is ready, offers local-provider setup when needed, generates the
   existing local AI brief when enabled, or opens a current brief. Raw notes
   are never overwritten.
5. Keyboard support: Command-Return saves, Command-Shift-T inserts a time
   marker, and Command-Shift-E runs the available enhancement action.

## Data and safety boundary

- `raw-notes.json` remains user-owned and is written only through
  `SessionNoteStore` on an explicit user action.
- The enhancement path freezes `transcript.json` and a raw-notes revision;
  it never supplies `mic.caf`, `system.caf`, or `mixed.m4a` to the model.
- The only provider is an explicit LM Studio loopback configuration. There is
  no remote fallback.
- Ready state is based on durable files and coordinator state, never a timer
  or a guessed completion state.

## Deferred deliberately

- A true live transcript panel and live checkpoints require incremental local
  transcription; this does not exist yet and is not faked.
- A single rich document model, an in-place enhanced-notes artifact, and a
  My notes/Enhanced toggle require a new artifact and migration design.
- Calendar, chat, sharing, and bots remain outside Quill's local-first scope.

## Acceptance checks

- While recording, the pad says that transcription arrives after stop and AI
  enhancement is unavailable.
- After stop, the lifecycle reports waiting, transcribing, failure, disabled,
  or transcript-ready truthfully.
- A selected note shows nearby transcript context only after a canonical
  transcript is readable.
- Provider setup and brief generation are always explicit and local.
- Hebrew text uses natural writing direction in the editor, timeline, and
  transcript context.
