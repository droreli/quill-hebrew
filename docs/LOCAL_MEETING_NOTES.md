# Local Meeting Notes and Briefs

## Status: integrated local-first thin slice

This guide documents Quill's available Local Meeting Notes and Meeting Briefs
flow. The native Notes, Meeting Brief, and Brief Provider Setup windows, plus
the explicit `quill brief` command, are available in this build. Generation is
still intentionally opt-in and depends on an already-running LM Studio server;
Quill never installs, starts, downloads, or updates it.

## What stays the same

Quill is a Mac-only local recorder and transcriber. System-audio capture needs
macOS 15 or later. It keeps clean, separately captured `mic.caf` and
`system.caf` tracks so each side can be transcribed independently; this is
important for overlapping speech. `mixed.m4a`, if enabled, is a listening copy
and is not a summary or transcription input.

The current local transcription choices are:

- Hebrew MLX on Apple-silicon Macs, including Hebrew-English decoding when
  configured;
- local English Parakeet through FluidAudio/Core ML; and
- an optional local Hebrew CPU fallback when its local runtime is available.

Apple silicon is required for the Hebrew MLX route, not for Hebrew as a
language in general. See [Hebrew MLX setup](HEBREW_MLX_SETUP.md) for its
one-time local runtime and model installation.

## Session contents

The session folder is the local lifecycle boundary:

```text
<session>/
  meta.json                         recording metadata
  mic.caf                           immutable microphone track
  system.caf                        immutable system-audio track
  mixed.m4a                         optional listening copy
  transcript.json                   canonical timed transcript
  transcript.md                     transcript reading view
  raw-notes.json                    user-owned notes
  artifacts/
    meeting-brief.json              generated canonical brief
    meeting-brief.md                generated reading view
```

`transcript.json` is the canonical transcript. `transcript.md` is its readable
rendering. `raw-notes.json` is the user's separate, timestamped note record;
generation must never overwrite it. The generated JSON captures source digests,
the frozen raw-note revision, engine/model metadata, and evidence references.
The Markdown artifact is a readable rendering of the generated brief.

## Workflow

1. Record and transcribe locally as usual.
2. During the meeting, open **Meeting notes…** and write concise raw notes.
   Their timestamps are meeting-relative user cues, not AI output. A note is
   stamped with the moment you started writing it, not the moment you saved.
   The pad's status strip always states the honest phase: recording (the
   transcript arrives after you stop), waiting for or running local
   transcription, transcription failed or disabled, or transcript ready.
   Quill does not transcribe live and the pad never pretends to.
3. Once the transcript is ready, selecting a note in the timeline shows the
   transcript lines spoken around that note's time. This is a deterministic
   lookup in `transcript.json`, not a model call, and it never reads audio.
4. After the canonical transcript is complete, choose **Enhance with AI
   brief** in the pad or **Generate meeting brief** in the brief window
   explicitly. If the local provider is not enabled, the pad offers provider
   setup instead and says why. There is no recording-time, automatic, or
   silent generation. See [Meeting Notes V2 plan](MEETING_NOTES_V2_PLAN.md)
   for the lifecycle, boundaries, and deferred items.
5. Quill supplies only the canonical transcript and a frozen raw-notes
   revision to the local summarization engine. It does not supply the raw
   audio tracks or `mixed.m4a` as summary input.
6. Review the read-only result. In this MVP, edit raw notes and regenerate to
   create a new brief; the viewer does not edit generated sections in place.
   Decisions, action items, topics, and questions must have transcript
   evidence. Raw notes remain user-owned context and are not promoted into
   generated claims. Unknown owners and dates should stay unknown rather than
   be invented.

Generated output is a reviewable draft, not a substitute for the recording or
transcript and not a guarantee that every statement is correct or complete.
An incomplete transcript should produce a warning, not invented coverage.
If raw notes change, the prior brief remains tied to its older frozen revision;
choose regeneration explicitly to create a new draft. Regeneration never
rewrites raw notes or the canonical transcript.

## LM Studio option

The local summarization provider is LM Studio, but it is opt-in
and disabled by default. Quill will accept only literal loopback endpoints:
`http://127.0.0.1` and `http://[::1]`. It rejects remote hosts, proxies, and
redirects. Keep LM Studio LAN serving disabled.

Install, update, and select LM Studio and its model yourself. Quill will never
launch, install, update, remove, or download either LM Studio or its models.
There is no cloud provider or fallback. If the provider is unavailable, keep
recording and transcription normally; use setup or retry only when you choose
to generate a brief. Provider edits are saved only through the explicit Save
action, and the CLI requires `--enable` for every direct generation invocation.

The configured `google/gemma-4-26b-a4b-qat` is a historic personal profile
default, not a public default or required model. Quill can record a model ID
and runtime details that LM Studio reports, but that is **reported runtime
provenance** only. It does not prove installed weights or checksums. See
[First setup on a clean Mac](FRESH_MAC_SETUP.md#6-optional-local-lm-studio-meeting-briefs)
for a loopback-only setup, a no-recording synthetic check, current
model-selection guidance, RAM tiers, model-directory discovery, timeouts, and
the low-memory option of leaving Briefs disabled.

Quill sends `reasoning_effort: none` because meeting extraction is a bounded
formatting task: default model thinking can consume the completion window and
leave the structured response empty. Each completion is capped at 2,048 tokens,
evidence identifiers are restricted to identifiers present in the current
transcript, and the per-request timeout is five minutes. Longer meetings remain
bounded through transcript-aligned extraction and hierarchical reduction; a
64K context is not required for this pipeline.

Because the model is installed outside Quill, review its distributor, license,
revision, size, storage location, and any supplied checksum before using it.
Quill does not download or verify those weights. After the user has installed
the model and LM Studio serves it on loopback, the generation request
does not require a cloud account or external network route.

## Privacy, retention, and recovery

The built-in product has no accounts, telemetry, cloud fallback, automatic
sharing, or hidden retention. Its local artifacts remain in the selected
recordings directory unless you deliberately copy, back up, upload, or process
them elsewhere. System audio can include unrelated music, notifications, and
other applications, so review what your Mac is playing before recording.

Quill does not currently offer an in-app source-audio deletion flow. Manage
retention from Finder and your backup system. Deleting a session removes the
audio, transcripts, notes, and brief artifacts it contains; once the files are
permanently removed and no backup remains, they cannot be retranscribed or
used to regenerate a brief. Moving an item to the Trash offers the normal
temporary recovery opportunity until the Trash is emptied.

For an interrupted or failed transcription, keep the session folder, review
`transcribe.log`, then use `quill doctor` and, where appropriate,
`quill retranscribe <session>`. These can recover from a local transcription
failure; they cannot recover deleted or never-captured audio.

The optional `on_stop` hook is user-configured code and sits outside Quill's
built-in privacy boundary. Review any command configured there, including its
network and retention behavior.

## Consent reminder

Before recording, tell participants and get consent where required. You are
responsible for applicable recording, workplace, privacy, contract, and
platform rules. This is a practical reminder, not legal advice or a claim that
Quill makes a recording lawful in every place or situation. Do not use Quill
to secretly record people or sensitive calls. See
[Privacy and consent](../PRIVACY_AND_CONSENT.md) for the full disclosure.
