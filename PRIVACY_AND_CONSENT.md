# Privacy and consent

## Scope and status

Quill is a local macOS meeting recorder, transcriber, and Local Meeting Notes
tool. The integrated Notes window, read-only Meeting Brief viewer, explicit
brief generation, and LM Studio controls described in
[the product requirements](docs/PRD_LOCAL_MEETING_NOTES.md) are available in
this build. This MVP intentionally requires an explicit **Save** for raw-note
edits and does not offer in-viewer editing of generated briefs.

Quill is Mac-only. Capturing system audio requires macOS 15 or later. The
local Hebrew MLX transcription path requires Apple silicon; the local English
Parakeet engine and the optional Hebrew CPU fallback have different runtime
requirements. See the README and the Hebrew MLX setup guide for the current
engine setup details.

## What Quill records and keeps locally

During a session, Quill records two separate clean tracks in the session
directory (by default under `~/Recordings`):

- `mic.caf` — the default microphone input;
- `system.caf` — all audio played by the Mac, which may include calls, music,
  notifications, or unrelated application audio.

The clean tracks are the transcription sources. If enabled by the user,
`mixed.m4a` is an optional listening copy only; it is not the primary
transcription source. Quill writes `meta.json`, a canonical timed
`transcript.json`, a human-readable `transcript.md`, and `transcribe.log` in
the same local session. Keeping microphone and system tracks separate helps
preserve intelligibility when people overlap.

The built-in transcription engines run on the Mac: Hebrew/English decoding
through the local MLX path when configured, local English Parakeet through
FluidAudio/Core ML, and an optional local Hebrew CPU fallback when available.
The optional Hebrew MLX setup separately downloads its runtime and model
weights. That download is a setup boundary, not an upload of recording audio.

## Local meeting notes and briefs

The session directory remains the boundary. It contains user-owned
`raw-notes.json` and generated artifacts at
`artifacts/meeting-brief.json` and `artifacts/meeting-brief.md`.

- Raw notes are separate from generated content and are never overwritten by
  a generation.
- A brief is generated only after a transcript is complete and the user takes
  an explicit generation action. There is no live, silent, or automatic
  meeting summary.
- The summary input is the canonical transcript plus a frozen raw-notes
  revision. It does not read `mic.caf`, `system.caf`, or `mixed.m4a`.
- Generated statements need transcript or raw-note evidence. A generated brief
  remains a draft for the user to review; it is not a guarantee of factual
  completeness or accuracy.

If raw notes change after generation, the existing brief is tied to its older
raw-note revision. Regeneration is an explicit action using the new frozen
revision; it never rewrites the raw notes.

See [Local Meeting Notes](docs/LOCAL_MEETING_NOTES.md) for the shipped flow,
artifact meanings, recovery, and the local-model setup boundary.

## Network, accounts, and model boundary

Quill's built-in recording and transcription have no cloud fallback, accounts,
telemetry, hidden retention service, or automatic sharing. Recordings,
transcripts, notes, and brief artifacts stay in the selected local
recordings directory unless you copy, back up, upload, or process them with
another tool yourself.

The existing `on_stop` setting can run a shell command selected by the user.
That command is outside Quill's built-in privacy boundary and may have its own
network or retention behavior; review it before configuring one.

The optional summarization provider is a user-operated LM Studio
server at a literal loopback address only: `http://127.0.0.1` or `http://[::1]`.
It is off by default. It does not permit remote hosts, proxies, redirects, or
cloud fallback. Users should keep LM Studio LAN serving disabled. Quill will
never launch, install, update, remove, or download LM Studio or its models;
the user installs and manages them separately. If that local provider or model
is unavailable, recording and transcription remain usable.

The initial personal model recommendation is
`google/gemma-4-26b-a4b-qat`; it is configurable and is not a public default.
With LM Studio, model ID, runtime version, and related metadata are reported by
the local server. They are recorded as **reported provenance**, not as
checksum-verified model identity. A checksum-verified claim requires a
separate verified model-installation path and must not be inferred from an LM
Studio response.

Before installing a model outside Quill, review its source, license, revision,
size, storage location, and any checksum supplied by its distributor. Quill
does not download or verify those weights. Once a model is already installed
and LM Studio is serving only on loopback, Quill's generation request
does not require a cloud account or external network route.

## Retention, removal, and recovery

Quill does not currently provide an in-app destructive source-audio deletion
flow. You control retention through the session directory and your own backups.
Removing a session removes its source audio, transcript, raw notes (when
available), and generated artifacts together; without a backup, a deleted
source cannot be retranscribed or used to regenerate a brief. Deleting only a
generated artifact leaves the source material intact but removes that output.

Use Finder's normal move-to-Trash flow if you want its ordinary, temporary
recovery opportunity; emptying the Trash or bypassing it can make removal
irreversible. Restore from a backup if one exists. For non-deletion failures,
preserve the session folder and inspect `transcribe.log`; `quill doctor` and
`quill retranscribe <session>` can help recover transcription without making a
new recording. Recovery cannot recreate audio that was never captured or has
already been permanently removed.

## Consent reminder

Recording can capture other participants and unrelated system playback. Before
starting, tell participants and obtain consent where it is required. You are
responsible for the recording, workplace, privacy, contractual, and platform
rules that apply to your meeting and location. This reminder is not legal
advice and does not claim that Quill makes any use universally compliant.

Do not use Quill to secretly record people or sensitive calls. Forks and
modified releases should retain an equally clear disclosure.
