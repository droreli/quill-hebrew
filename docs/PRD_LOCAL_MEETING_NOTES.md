# PRD: Quill Notes and Local Meeting Briefs

Status: Shipped MVP thin slice
Owner: Quill Hebrew  
Platform: Apple-silicon Mac, macOS 15+  
Privacy posture: local-only after an explicit model download

## 1. Product thesis

Quill should become a private local meeting notebook, not a cloud meeting bot.
The user writes a few short cues while a meeting is being recorded. After the
existing local transcript is ready, an on-device model uses the transcript and
those cues to create a concise, evidence-linked meeting brief.

The core value is **user-directed recall**: the raw notes say what deserves
attention; the transcript supplies detail and evidence.

Granola validates the interaction pattern: sparse user notes guide an AI to add
context and structure from the transcript. Quill adopts that interaction while
keeping capture, notes, transcripts, and generation on the user's Mac. Granola
is product inspiration, not Quill's privacy or implementation model.

References:

- [Granola: AI-enhanced notes](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes)
- [Granola: taking notes](https://docs.granola.ai/help-center/taking-notes/taking-notes-in-granola)
- [Granola: transcription](https://docs.granola.ai/help-center/taking-notes/transcription)

## 2. Target user and job

Primary user: a Mac user in Hebrew, English, or mixed-language meetings who
wants to stay present and still leave with a trustworthy record.

Job to be done:

> While I am in a meeting, let me flag the few things that matter in shorthand.
> When it ends, give me a compact follow-up draft without sending the meeting
> anywhere.

## 3. Product principles

1. Raw notes are user-owned and are never overwritten by generated content.
2. Audio and the canonical transcript remain immutable inputs to the brief.
3. Every generated decision and action item must point to transcript evidence
   or a raw note. Unsupported claims are rejected or clearly marked inferred.
4. Recording and transcription continue to work when the summary model is
   missing, slow, or broken. There is never a cloud fallback.
5. Model installation is a separate, explicit action showing source, size,
   license, revision, checksum, and storage location.
6. The first release generates only after a completed transcript and an
   explicit user action. No recording-time model contention or silent jobs.
7. Hebrew, English, and mixed output must preserve names, numbers, and natural
   text direction.

## 4. MVP user flow

### Before recording

- The existing recording setup remains intact.
- The controls explain that the microphone and all captured system audio stay
  local and that the user is responsible for participant consent.
- A meeting-note template can be selected: `General`, `Decision`,
  `Customer call`, or `Blank`.

### During recording

- A keyboard-first Notes window opens or can be opened from Quill.
- The user writes short Markdown-style headings and bullets.
- A note can be submitted with an automatic meeting-relative timestamp.
- The user explicitly saves each note; each save writes atomically to the
  active session without blocking audio.
- Closing the window does not stop recording or lose notes.

### After recording

- Quill completes its existing clean-track transcription first.
- The user chooses **Generate meeting brief**.
- If the local model is unavailable, Quill shows setup/retry information while
  leaving recording and transcription fully usable.
- Generation reads only the canonical transcript plus a frozen raw-note
  revision. It never reads `mic.caf`, `system.caf`, or `mixed.m4a`.

### Review

- Quill presents separate, read-only sections:
  - Overview
  - Key topics
  - Decisions
  - Action items
  - Open questions
  - Warnings / incomplete coverage
- Every nontrivial item exposes its source transcript timestamp(s).
- The user can edit and explicitly save raw notes, then regenerate. Existing
  generated output records which raw-note revision and transcript digest it
  used. In-place generated-brief editing is deliberately out of this MVP.
- Markdown and JSON outputs remain available in the session folder.

## 5. MVP scope

### Included

- Per-session timestamped raw notes with explicit, local atomic saves.
- Native AppKit notes window that remains usable while recording.
- Explicit post-transcript brief generation.
- Fully local Hebrew/English/mixed-language model path.
- Versioned JSON contracts and human-readable Markdown.
- Evidence links from generated items to canonical transcript segments.
- Progress, cancellation, failure, retry, and stale-note states.
- A CLI path for fixture testing and recovery:

  ```text
  quill brief <session-directory>
  ```

- A native meeting-brief viewer and Finder reveal actions.
- An opt-in LM Studio loopback provider, disabled until explicitly configured.
- Unit/integration fixtures for Hebrew, English, mixed language, overlaps, and
  incomplete transcripts.

### Explicitly not in MVP

- Live or automatic summaries during recording.
- Cross-meeting search, chat, memory, or embeddings.
- Calendar, email, CRM, sharing, accounts, cloud sync, or telemetry.
- A meeting bot, automatic participant messages, or legal-compliance claims.
- In-app deletion of source audio. Deletion UX requires a separate destructive-
  action design and recovery plan.
- Automatic post-meeting generation before latency, battery, and quality are
  measured and approved.
- In-place editing of generated briefs or automatic/debounced raw-note saves.

## 6. Data contracts

The existing session folder remains the security and lifecycle boundary:

```text
<session>/
  meta.json                         recording metadata
  mic.caf                           immutable clean input
  system.caf                        immutable clean input
  mixed.m4a                         optional listening copy
  transcript.json                  canonical transcript
  transcript.md                    transcript reading view
  raw-notes.json                    user-owned notes
  artifacts/
    meeting-brief.json              generated canonical artifact
    meeting-brief.md                generated reading view
```

`meta.json` gains additive `schema_version` and `session_id` keys. Older
sessions without them remain readable.

### `raw-notes.json`

```json
{
  "schema_version": "quill.raw-notes.v1",
  "session_id": "UUID",
  "revision": 12,
  "template": "general",
  "updated_at": "ISO-8601",
  "notes": [
    {
      "id": "UUID",
      "text": "Decision: start with a two-week pilot",
      "captured_at_ms": 542000,
      "created_at": "ISO-8601",
      "updated_at": "ISO-8601"
    }
  ]
}
```

The notes store is the sole writer, increments `revision`, and uses atomic
writes. AI output is never written to this file.

### `artifacts/meeting-brief.json`

```json
{
  "schema_version": "quill.meeting-brief.v1",
  "id": "UUID",
  "created_at": "ISO-8601",
  "language": "mixed",
  "inputs": {
    "transcript_sha256": "hex",
    "transcript_segment_count": 184,
    "raw_notes_revision": 12
  },
  "generator": {
    "engine": "lmstudio-openai",
    "endpoint": "http://127.0.0.1:1234",
    "runtime_version": "reported",
    "model_id": "google/gemma-4-26b-a4b-qat",
    "model_revision": null,
    "quantization": "4-bit",
    "provenance": "reported",
    "local_only": true
  },
  "overview": "...",
  "topics": [],
  "decisions": [],
  "action_items": [],
  "open_questions": [],
  "warnings": []
}
```

Each topic, decision, action item, and question contains `evidence` entries.
The model may emit only stable segment IDs (`s000001`, `s000002`, ...). Quill
validates those IDs and enriches them from `transcript.json`:

```json
{
  "segment_id": "s000091",
  "transcript_json_pointer": "/segments/90",
  "start_ms": 754000,
  "end_ms": 761200,
  "speaker": "them"
}
```

This prevents a model from inventing timestamps. For old transcripts, segment
IDs are derived deterministically from array order.

## 7. Local model direction

### MVP provider: LM Studio loopback

The first working slice uses the LM Studio server already available on the
user's Mac. It is an opt-in `SummarizationEngine` implementation, not a cloud
API and not a replacement for Quill's Whisper/Parakeet transcription engines.

- The only accepted endpoints are literal `127.0.0.1` and `::1` loopback.
- System proxies are disabled and redirects are refused.
- Quill never launches, installs, updates, or downloads through LM Studio.
- Server/model absence returns `provider_unavailable` without affecting capture
  or transcription.
- The selected model is configurable and recorded with each artifact.
- Provider model identity is reported rather than checksum-verified; artifacts
  record `provenance: reported`.

The initial personal profile uses `google/gemma-4-26b-a4b-qat`, while the
fixture bake-off compares it with `google/gemma-4-12b-qat`,
`qwen/qwen3.8-27b`, `qwen3.8-27b-uncensored-mlx`, and the available 35B-A3B
candidate. No model becomes a public default without evidence from Hebrew,
English, and mixed-language fixtures. An uncensored fine-tune may be used
personally if it wins, but it is not a recommended public default until its
license, abstention, and hallucination behavior pass the same gates.

### Portable provider later

An embedded MLX Swift or pinned `llama.cpp` engine may later provide a
self-contained public installation without LM Studio. It uses the same
`SummarizationEngine` and evidence-validation contracts and remains behind a
separate model, license, checksum, memory, and performance gate.

### Inference policy

1. Label transcript segments deterministically.
2. Chunk on segment boundaries using model token limits.
3. Extract constrained facts, decisions, actions, and questions per chunk.
4. Reduce those facts into the final brief while retaining segment IDs.
5. Validate JSON, reject unknown IDs, enrich timestamps from the transcript.
6. Drop unsupported claims. Unknown owner or due date remains `null`.

Generation runs on a serial background actor only after transcription has
released its engine. It supports cancellation, timeout, output-size limits,
and atomic final writes.

## 8. Architecture boundaries

- `AppController` (`@MainActor`): UI and recording state only.
- `RecordingSession`: acquisition only; adds session identity but never writes
  notes or generated artifacts.
- `SessionNoteStore` actor: sole writer of `raw-notes.json`.
- `TranscriptionCoordinator`: audio-derived transcript only; unchanged queue
  semantics and no AI-artifact responsibilities.
- `PostMeetingCoordinator` actor: explicit brief queue, cancellation, retry,
  stale-input detection, and model resource lifecycle.
- `SummarizationEngine` protocol: typed boundary for MLX/fallback engines.
- `MeetingBriefStore`: validates and atomically writes generated artifacts.
- Existing `on_stop`: remains a transcript-ready advanced hook; it does not
  become the trusted AI pipeline.

## 9. Acceptance criteria

### Notes

- A user can type `# Decisions` and `- Dana: send proposal Friday` during a
  recording; quitting/reopening the Notes window preserves it.
- An explicit note save does not measurably interrupt either audio track.
- A crash may lose the current unsaved editor draft; successfully saved raw
  notes are written atomically.
- Raw notes remain byte-identical through brief generation and regeneration.

### Brief quality and evidence

- Every decision and action item has at least one valid source reference.
- Unknown owners/dates are `null`; Quill does not guess them.
- Unknown segment IDs or malformed model JSON fail the generation job without
  replacing the last valid artifact.
- A changed raw-note revision is shown as stale and can be regenerated.
- Incomplete transcripts produce a visible warning, not invented coverage.

### Reliability and privacy

- Missing/invalid model state never blocks recording or transcription.
- After approved setup, a network-denied run generates a valid brief or a clear
  local-model error. No cloud/API fallback exists.
- `meta.json`, raw tracks, `transcript.json`, and raw notes keep the same hashes
  before and after generation.
- Interrupted artifact writes do not leave a valid partial JSON file.
- Restart can discover incomplete explicit jobs without re-recording or
  retranscribing source audio.

### UX and accessibility

- Notes are keyboard-first and expose VoiceOver names, focus order, and save
  state without relying on color.
- Hebrew content uses natural RTL while controls retain system layout direction.
- The brief viewer clearly distinguishes user notes, generated content, and
  transcript evidence.
- Progress and failure states never imply that recording has stopped or failed.

## 10. Product metrics without telemetry

Metrics are local and user-visible or measured against repository fixtures:

- Time from transcript-ready to first brief.
- Evidence coverage for decisions and actions.
- Unsupported-claim rate in QA fixtures.
- Owner/date abstention precision.
- Hebrew, English, and code-switched quality rubric.
- Regeneration and user-edit counts stored only within the local session if the
  user enables local product diagnostics.
- Peak memory, thermal state, and wall time across supported Mac memory tiers.
- A per-model bake-off report covering JSON validity, evidence coverage,
  unsupported claims, owner/date abstention, latency, and peak memory.

## 11. Risk gates

1. **Product gate:** approve explicit, post-transcript generation for MVP.
2. **Schema gate:** old and current sessions decode without mutation.
3. **Privacy gate:** no off-device generation path or silent download. The only
   permitted network client is the opt-in loopback provider with a literal-host
   allow-list, proxies disabled, and redirects refused.
4. **Model gate:** Hebrew/mixed benchmark passes before a model becomes a
   default. Reported/unverifiable provider provenance and uncensored fine-tunes
   cannot become the recommended public default.
5. **Resource gate:** transcription releases GPU resources before generation;
   timeout and cancellation are verified. External-provider memory cannot be
   controlled by Quill, so provider use never blocks recording and contention
   is surfaced as a warning.
6. **Quality gate:** evidence validation and unsupported-claim rejection pass.
7. **Release gate:** automated tests, release build, offline run, RTL/VoiceOver
   review, and manual no-recording UI verification pass.

## 12. Later phases

- Phase 2: optional live checkpoints after incremental transcription exists.
- Phase 3: local cross-meeting search/chat with an explicit local index.
- Phase 4: user-approved calendar context and outbound integrations, each with
  a separate privacy posture. No cloud feature is implied by this PRD.
