# Quill Hebrew

An independent, Hebrew-ready fork of
[digimata/quill](https://github.com/digimata/quill): a minimal, fully local
macOS meeting recorder + transcriber. One menu-bar click records your mic and
all system audio as two separate clean tracks; when you stop, Quill transcribes
both on-device and merges their timed segments into one chronological reading
transcript. Nothing ever leaves the machine after the one-time model download.

> **macOS only.** Recording system audio requires macOS 15 or later. The
> optional Hebrew MLX engine additionally requires an Apple-silicon Mac.
> This is an independent fork, not affiliated with or endorsed by digimata,
> ivrit.ai, MLX Community, Apple, or Fluid Inference.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

### Enable the local Hebrew MLX engine

The local English engine is **Parakeet TDT 0.6B v2** via FluidAudio/Core ML.
This fork is configured for local Hebrew transcription via
`mlx-community/ivrit-ai-whisper-large-v3-turbo-mlx`, an MLX conversion of the
Apache-2.0 `ivrit-ai/whisper-large-v3-turbo` model. The setup is a one-time
download of roughly 1.6 GB; the audio is never uploaded.

On an Apple-silicon Mac, run:

```sh
./scripts/install-hebrew-mlx.sh
```

The script installs the local Python runtime, `ffmpeg`, and the MLX model, then
writes the two local paths Quill needs to `~/.config/quill/config.json`. Review
the script before running it; it changes only your local development/runtime
environment and downloads the model from Hugging Face. For manual setup and
troubleshooting, see [docs/HEBREW_MLX_SETUP.md](docs/HEBREW_MLX_SETUP.md).

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready. Choose **Open controls…** from the feather menu before
   a meeting to select language, local engine, timestamps, visible speaker
   labels, and optional mixed-audio listening copy.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |
| `mixed.m4a` | optional listening copy of both tracks; never the primary transcript |

Two tracks are intentional: speech models do better on clean single-source
audio, and keeping mic-vs-system separate preserves intelligibility when two
people overlap. The reading transcript is chronological and hides speaker
labels by default, so it feels like one continuous conversation; its canonical
`transcript.json` always retains `me` / `them` for automation or a labelled
view. The optional `mixed.m4a` is handy for playback, but can make overlap
harder to hear and is not fed to transcription. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Built in, on-device, automatic. On this Mac, the default is the same proven
**Hebrew Whisper Large V3 Turbo MLX** model used by Tamlil, running locally on
the Apple GPU. It supports Hebrew and automatic Hebrew-English conversation
decoding; the pinned model is already cached locally, and the runtime sets
offline flags so it cannot fall back to a cloud service. The upstream Hebrew
model is Apache-2.0 licensed. If the MLX runtime or GPU is unavailable, Quill
falls back to local English **Parakeet TDT 0.6B v2** via
[FluidAudio](https://github.com/FluidInference/FluidAudio). A local Hebrew CPU
fallback is also selectable in controls when Tamlil's existing CPU command is
available.

Each clean track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Privacy and consent

Quill records your microphone and **all audio played by the Mac** while a
session is active. Get consent where required and comply with the recording,
workplace, and privacy rules that apply to you. See
[PRIVACY_AND_CONSENT.md](PRIVACY_AND_CONSENT.md) before publishing or using a
modified build.

## Upcoming local meeting notes and briefs

The next local-first phase proposes separate, timestamped raw notes and an
explicit post-transcript meeting-brief draft. It is **planned, not yet an
integrated released UI**: do not expect Notes, brief generation, or LM Studio
controls in the current app until the integration owner confirms them. The
planned brief uses only the canonical transcript and a frozen raw-note revision
(not `mic.caf`, `system.caf`, or optional `mixed.m4a`), keeps raw notes separate
from generated content, and has no cloud fallback, accounts, telemetry, or
automatic sharing.

The proposed LM Studio provider is opt-in and literal-loopback only
(`127.0.0.1` or `::1`); Quill will never manage LM Studio or its models. The
initial personal recommendation, `google/gemma-4-26b-a4b-qat`, is configurable
and recorded with **reported**, not checksum-verified, runtime provenance.
Read [Local Meeting Notes](docs/LOCAL_MEETING_NOTES.md) and
[Privacy and consent](PRIVACY_AND_CONSENT.md) for the proposed flow, model
boundary, retention, removal, recovery, and consent reminder.

## License and third-party components

The Quill codebase is MIT-licensed; retain its copyright and license notice in
copies and forks. The separate Hebrew model is Apache-2.0 licensed. This
repository does not ship model weights—users download them directly using the
documented setup. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the
components and redistribution obligations.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": {
    "enabled": true,
    "engine": "mlx-hebrew",
    "language": "automatic",
    "timestamps": true
  },
  "speaker_labels": false,
  "export_mixed_audio": false,
  "on_stop": "my-hook"
}
```

Changes made in **Open controls…** are saved here automatically. In
particular, **Show speaker labels** and **Save a listening copy** stay enabled
for future recordings after you turn them on.

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `transcription.engine` — `mlx-hebrew` (default local GPU), `parakeet`
  (local English Core ML), or `hebrew-cpu` (Tamlil's local CPU fallback).
- `transcription.language` — `automatic` (default; Hebrew and English),
  `hebrew`, or `english`. The controls window exposes these as plain-language
  choices.
- `transcription.timestamps` — show/hide timestamps in `transcript.md`;
  `transcript.json` always retains exact timing.
- `speaker_labels` — show/hide `me` / `them` in `transcript.md`; the JSON
  transcript always retains those labels.
- `export_mixed_audio` — also save `mixed.m4a` for listening. The clean tracks
  remain the transcription source because overlapping speech is clearer there.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill run --export-mixed-audio # additionally make mixed.m4a for listening
quill run --controls-only    # open the controls window without recording
quill doctor                 # check permissions, recordings folder, models
quill verify-mix             # synthetic, no-permission mixed-audio verification
quill verify-mlx <audio>     # check Quill's local MLX bridge and timed output
quill retranscribe <session> # re-run a finished session without recording again
quill install --launch-at-login
quill install --uninstall
```

## Stack

Product planning for the next local-first phase:

- [PRD: Quill Notes and Local Meeting Briefs](docs/PRD_LOCAL_MEETING_NOTES.md)
- [Parallel Terra High work packages](docs/WORK_PACKAGES_LOCAL_MEETING_NOTES.md)

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **MLX Whisper / pinned ivrit.ai Hebrew Turbo model** — local Apple-GPU
  Hebrew and Hebrew-English transcription
- **FluidAudio / Parakeet** — local Core ML English engine / fallback
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- The Hebrew MLX engine is local and preferred here. If it cannot start,
  Quill warns and uses the local Parakeet fallback; select the CPU fallback in
  controls if the GPU runtime is unavailable.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
