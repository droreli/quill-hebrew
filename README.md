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

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot),
with the same local Swift core and a normal macOS app bundle for Finder,
Spotlight, the Dock, and launch at login.

> **New to Quill? Start with [First setup on a clean Mac](docs/FRESH_MAC_SETUP.md).**
> It is the complete clone, build, install, permissions, Hebrew/English engine,
> local-LM-Studio, upgrade, rollback, and Codex/Claude handoff guide. Nothing
> in that guide starts a recording.

## Install

If you have not cloned the repository yet, use the exact clone command in
[First setup on a clean Mac](docs/FRESH_MAC_SETUP.md#1-prerequisites-and-clone).
From that checkout:

```sh
cd "$HOME/Developer/quill-hebrew"
./scripts/install-app.sh
open -a Quill
```

This builds and ad-hoc signs `~/Applications/Quill.app` and registers a
per-user login agent. Open it explicitly after installation with
`open -a Quill` or Spotlight by searching for **Quill**. The installer does
not record audio or change Quill's saved configuration. The historical
single-binary installation remains supported for developers.

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

### Enable the local Hebrew MLX engine

The local English engine is **Parakeet TDT 0.6B v2** via FluidAudio/Core ML.
It is not Apple's built-in speech recognizer: it is a third-party model running
fully on-device through Apple's Core ML runtime. Quill keeps it as the
English-only default because FluidAudio recommends v2 for English and reports
2.1% average WER and 145.8x overall real-time throughput on its M4 Pro
[benchmark](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md).
This fork is configured for local Hebrew transcription via
`mlx-community/ivrit-ai-whisper-large-v3-turbo-mlx`, an MLX conversion of the
Apache-2.0 `ivrit-ai/whisper-large-v3-turbo` model. The setup is a one-time
download of roughly 1.6 GB; the audio is never uploaded.

On an Apple-silicon Mac, run:

```sh
./scripts/install-hebrew-mlx.sh
"$HOME/Applications/Quill.app/Contents/MacOS/quill" doctor
```

The script uses available Python 3 to create a local virtual environment,
installs `ffmpeg` through Homebrew, downloads the MLX model, then writes the
two local paths Quill needs to `~/.config/quill/config.json`. Review the
script before running it; it changes only your local development/runtime
environment and downloads the model from Hugging Face. For manual setup and
troubleshooting, see [docs/HEBREW_MLX_SETUP.md](docs/HEBREW_MLX_SETUP.md).

## How to use

1. **Run it** (open **Quill** from Spotlight, or let the registered
   LaunchAgent start it at login).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready. Choose **Open controls…** from the feather menu before
   a meeting to select language, local engine, timestamps, visible speaker
   labels, and optional mixed-audio listening copy. Choose **Meeting library…**
   to browse any completed local session one at a time; its actions always use
   the selected session, never an inferred latest transcript.

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

Built in and on-device. After the optional Hebrew MLX setup, the default is
**Hebrew Whisper Large V3 Turbo MLX**, running locally on the Apple GPU. It
supports Hebrew and automatic Hebrew-English conversation decoding; after its
one-time setup it runs locally with no cloud fallback. The upstream Hebrew
model is Apache-2.0 licensed. A local Hebrew CPU fallback is selectable in
controls when its local command is available.

Each clean track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

For Hebrew or automatic-language sessions, an unavailable Hebrew MLX runtime
is reported as a transcription failure rather than silently producing an
English Parakeet transcript. Select the explicit local Hebrew CPU engine when
that fallback is appropriate. For English-only sessions, explicitly select
**English only** and **English Parakeet — local** in Open controls….

## Privacy and consent

Quill records your microphone and **all audio played by the Mac** while a
session is active. Get consent where required and comply with the recording,
workplace, and privacy rules that apply to you. See
[PRIVACY_AND_CONSENT.md](PRIVACY_AND_CONSENT.md) before publishing or using a
modified build.

## Local meeting notes and briefs

Quill includes separate, timestamped raw notes and an explicit post-transcript
meeting-brief draft. Open **Meeting notes…** while recording to capture local
notes with meeting-relative timestamps. After a `transcript.json` exists, open
**Meeting brief…** and choose Generate; it is never automatic and never reads
`mic.caf`, `system.caf`, or optional `mixed.m4a`. The brief uses only the
canonical transcript and a frozen raw-note revision, keeps raw notes separate
from generated content, and has no cloud fallback, accounts, telemetry, or
automatic sharing.

### Meeting library and live-transcription boundary

The native **Meeting library** lists every completed recording, including ones
still waiting for transcription. Select a session to inspect its transcript
state, source-track and optional listening-copy availability, and whether a
brief exists. From that detail, open its notes or its brief; regenerating a
brief always uses that selected session’s canonical transcript and notes.

Quill does not currently show live transcript text while a recording is in
progress. This is deliberate: the default Hebrew MLX route is process-per-call
and a 15-second loop would reload the model or re-read growing audio, risking
the final canonical transcription. See
[Incremental local transcription limits](docs/LIVE_TRANSCRIPTION_LIMITS.md)
for the required safe architecture and M5/64 GB operating envelope.

The LM Studio provider is opt-in and literal-loopback only
(`127.0.0.1` or `::1`); Quill will never manage LM Studio or its models. The
configured historic profile, `google/gemma-4-26b-a4b-qat`, is configurable
and recorded with **reported**, not checksum-verified, runtime provenance.
It is not a universal model or context recommendation. Quill disables model
thinking for this bounded structured-output task, constrains evidence IDs to
the actual transcript, caps each completion, and allows up to five minutes per
local request.
Read [First setup on a clean Mac](docs/FRESH_MAC_SETUP.md#6-optional-local-lm-studio-meeting-briefs),
[Local Meeting Notes](docs/LOCAL_MEETING_NOTES.md), and
[Privacy and consent](PRIVACY_AND_CONSENT.md) for the shipped flow, model
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
  "meeting_brief_provider": {
    "enabled": false,
    "endpoint": "http://127.0.0.1:1234",
    "model": "google/gemma-4-26b-a4b-qat"
  },
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
- `transcription.language` — `automatic` (Hebrew + English with the MLX
  engine), `hebrew`, or `english`. The controls window exposes these as
  plain-language choices. English-only transcription requires choosing both
  `english` and the `parakeet` engine; it is not an automatic fallback.
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
- `meeting_brief_provider` — optional LM Studio settings. It is disabled by
  default and persists only when you explicitly save **Brief provider setup…**.

## CLI

The app-bundle install does **not** create a global `quill` command. For the
installed app, set a local shell variable first:

```sh
QUILL_BIN="$HOME/Applications/Quill.app/Contents/MacOS/quill"
```

```sh
"$QUILL_BIN"                 # run the menu-bar daemon (^C to quit)
"$QUILL_BIN" run --out <dir> # custom recordings root (default ~/Recordings)
"$QUILL_BIN" run --export-mixed-audio # additionally make mixed.m4a for listening
"$QUILL_BIN" run --controls-only # open the controls window without recording
"$QUILL_BIN" doctor          # check permissions, recordings folder, models
"$QUILL_BIN" verify-mix      # synthetic, no-permission mixed-audio verification
"$QUILL_BIN" verify-mlx <audio> # check Quill's local MLX bridge and timed output
"$QUILL_BIN" retranscribe <session> # re-run a finished session without recording again
"$QUILL_BIN" brief <session> --enable # explicitly generate with an already-running local LM Studio
"$QUILL_BIN" brief <session> --enable --endpoint http://127.0.0.1:1234 --model <model-id>
"$QUILL_BIN" install --launch-at-login
"$QUILL_BIN" install --uninstall
```

A developer-managed global `quill` binary can use the same subcommands.

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill run --export-mixed-audio # additionally make mixed.m4a for listening
quill run --controls-only    # open the controls window without recording
quill doctor                 # check permissions, recordings folder, models
quill verify-mix             # synthetic, no-permission mixed-audio verification
quill verify-mlx <audio>     # check Quill's local MLX bridge and timed output
quill retranscribe <session> # re-run a finished session without recording again
quill brief <session> --enable # explicitly generate with an already-running local LM Studio
quill brief <session> --enable --endpoint http://127.0.0.1:1234 --model google/gemma-4-26b-a4b-qat
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
- **FluidAudio / Parakeet** — explicitly selected local Core ML English engine
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- The Hebrew MLX engine is local and preferred here. If it cannot start for a
  Hebrew or automatic-language session, Quill fails visibly rather than using
  English Parakeet; select the CPU fallback in controls if appropriate.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
