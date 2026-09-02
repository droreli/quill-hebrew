# Quill Hebrew: first setup on a clean Mac

This is the public, reproducible setup path for a friend starting from an
empty Mac. It separates the required recorder app from optional Hebrew
transcription and optional local AI briefs. Read it before giving Quill
microphone or system-audio access.

> **What this guide does not promise:** it has not been run end-to-end on a
> clean Mac. It is based on this repository's current scripts and source code.
> The only action that starts a recording is a deliberate click in Quill's
> menu. None of the install commands below records audio.

## At a glance

| Component | Required for | Download / disk expectation |
| --- | --- | --- |
| Git + Xcode Command Line Tools / Swift | clone and build | Apple developer tools; allow several GB for the tools and build cache |
| Quill app | recording | built locally; no bundled speech-model weights |
| Homebrew, Python, ffmpeg, MLX Hebrew model | Hebrew or Hebrew+English transcription on Apple silicon | model is currently about 1.61 GB, plus virtual environment and build/download headroom |
| Parakeet | English-only transcription | first English transcription downloads about 600 MB into FluidAudio's managed cache |
| LM Studio + one loaded local model | optional Meeting Brief only | model size and RAM depend on the model, quantization, and context length |

**Required hardware:** macOS 15 or later for Quill's system-audio capture.
Apple silicon is required for the optional MLX Hebrew route, but not for
recording itself or for selecting the local English Parakeet route. Use enough
free disk space for the option you choose.

בקיצור: מתקינים את Quill בלי הקלטה. לתמלול עברית על Mac עם שבב M מתקינים
פעם אחת את רכיבי MLX. לתמלול אנגלית בלבד בוחרים במפורש **English only** וגם
**English Parakeet — local**.

## 1. Prerequisites and clone

Open Terminal. Install Apple's command-line tools, accept the dialog, then
open a new Terminal window when it finishes:

```sh
xcode-select --install
swift --version
```

Install Git if it is not already available. A common route is the Command Line
Tools command above; verify with:

```sh
git --version
```

Clone into the exact directory below. Do not clone into an existing project
folder or into a recordings directory:

```sh
mkdir -p "$HOME/Developer"
git clone https://github.com/droreli/quill-hebrew.git "$HOME/Developer/quill-hebrew"
cd "$HOME/Developer/quill-hebrew"
```

Build before installing so compiler errors are visible:

```sh
swift build -c release
```

## 2. Install and open Quill

From the repository root:

```sh
./scripts/install-app.sh
open -a Quill
```

The script builds an ad-hoc-signed app at `~/Applications/Quill.app` and
registers a per-user LaunchAgent for login. It does not edit
`~/.config/quill/config.json`, install transcription models, or begin a
recording. Its LaunchAgent uses the app-bundle executable and starts it at
login; open Quill explicitly after install to confirm that the menu-bar feather
appears.

Useful locations:

| Location | Purpose |
| --- | --- |
| `~/Applications/Quill.app` | installed application |
| `~/Library/LaunchAgents/com.digimata.quill.plist` | reversible login registration |
| `/tmp/quill.out.log`, `/tmp/quill.err.log` | login-agent output and errors |
| `~/.config/quill/config.json` | optional Quill preferences |
| `~/Recordings/` | default session folder root |

Confirm the login registration without recording:

```sh
launchctl print "gui/$(id -u)/com.digimata.quill"
```

If you do not want Quill to start at login:

```sh
"$HOME/Applications/Quill.app/Contents/MacOS/quill" install --uninstall
```

## 3. Consent and macOS permissions

Before any test recording, tell participants that Quill captures both your
microphone and all system audio played by the Mac. Obtain consent where
required. See [Privacy and consent](../PRIVACY_AND_CONSENT.md).

Permissions are requested only after you deliberately choose **Start
recording** from the Quill menu. When macOS asks, choose the Quill app for:

1. **Microphone:** System Settings → Privacy & Security → Microphone.
2. **Screen & System Audio Recording:** System Settings → Privacy & Security
   → Screen & System Audio Recording.

Do not grant permissions to a similarly named app. If macOS says a change
needs Quill to quit and reopen, follow that system prompt; do not assume a
restart is always required. No installer, agent, Codex prompt, or Claude prompt
should grant these permissions automatically.

## 4. Choose transcription intentionally

Open the Quill feather → **Open controls…** before a meeting. The choices are
saved for future recordings in `~/.config/quill/config.json`.

### Hebrew or Hebrew+English

Use **Hebrew + English** with **Hebrew MLX — Apple GPU** after completing the
optional MLX setup below. If that runtime is missing, Hebrew and automatic
sessions fail visibly rather than producing a quiet English-only transcript.
The separately selectable **Hebrew CPU — fallback** requires its own local
runtime; Quill does not install it.

### English only

Choose both:

1. **English only** under Meeting language.
2. **English Parakeet — local** under Engine.

Parakeet is an English local Core ML engine. On its first actual English
transcription it downloads the model once (currently about 600 MB) into
FluidAudio's managed cache, so be online for that deliberately consented test.
It is not an automatic fallback for a Hebrew or automatic-language session.

Run this read-only readiness check before the first meeting:

```sh
"$HOME/Applications/Quill.app/Contents/MacOS/quill" doctor
```

The doctor can report that a model has not yet been downloaded. It does not
download models or start a recording.

## 5. Optional: Hebrew MLX setup (Apple silicon)

Skip this section for English-only Parakeet or recording without transcription.
For Apple silicon, first install Homebrew only if `brew --version` fails:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
eval "$(/opt/homebrew/bin/brew shellenv)"
```

Then install Python and the local audio dependency, and run Quill's reviewed
setup script:

```sh
brew install python ffmpeg
cd "$HOME/Developer/quill-hebrew"
./scripts/install-hebrew-mlx.sh
"$HOME/Applications/Quill.app/Contents/MacOS/quill" doctor
```

The script creates a dedicated Python environment at
`~/.local/share/quill-hebrew/mlx-whisper`, downloads
`mlx-community/ivrit-ai-whisper-large-v3-turbo-mlx` to
`~/Library/Application Support/quill-hebrew/models/`, and merges only the
`transcription` settings it owns into Quill's config. It downloads from
Hugging Face and does not upload recordings. The model card currently lists
the MLX model at about 1.61 GB; reserve additional working space. See the
[model card](https://huggingface.co/mlx-community/ivrit-ai-whisper-large-v3-turbo-mlx)
and [detailed Hebrew setup](HEBREW_MLX_SETUP.md).

## 6. Optional: local LM Studio Meeting Briefs

Meeting Briefs are separate from recording and transcription. They are
disabled by default, run only after a completed `transcript.json`, and never
read `mic.caf`, `system.caf`, or `mixed.m4a`. If memory is tight, leave
the provider disabled; recording, transcription, notes, and the library still
work.

### Install, load, and serve locally

1. Install LM Studio from [its official download page](https://lmstudio.ai/).
2. In LM Studio, use **Discover** / **My Models** to download and load a model.
   Loading allocates memory for model weights and context.
3. In the **Developer** tab, keep **Serve on Local Network** off and toggle
   **Start server**. LM Studio's default local server is
   `http://localhost:1234`; Quill specifically requires the literal endpoint
   `http://127.0.0.1:1234` (or `http://[::1]:1234`).
4. In Quill, feather → **Brief provider setup…**. Check **Enable LM Studio
   provider**, enter `http://127.0.0.1:1234`, choose a model, press **Check
   availability**, then press **Save provider settings**.

**Check availability** only requests LM Studio's `/v1/models` inventory with
a five-second timeout. It does not generate a brief, download a model, or
verify a model checksum. A listed identifier is reported provenance, not proof
of particular weights.

Use this no-recording synthetic check after the model is loaded. Replace the
placeholder with an ID returned by the first command:

```sh
curl --fail --silent http://127.0.0.1:1234/v1/models
QUILL_LM_MODEL='replace-with-an-id-from-v1-models'
curl --fail --silent http://127.0.0.1:1234/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$QUILL_LM_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: local model ready\"}],\"max_tokens\":16}"
```

This sends only the fixed synthetic sentence to your local server. Do not paste
a recording, transcript, API key, or personal note into a troubleshooting
command. Quill itself supports no authentication header, remote host, proxy,
or redirect for this provider.

### Model and memory choice

Quill has no universal, benchmarked “best” LM Studio model. Compatibility is
established for a particular local model only when it appears in Quill's
**Check availability** list and completes the synthetic local request above.
The configured `google/gemma-4-26b-a4b-qat` is a historic personal profile
default, not a public recommendation and not a requirement.

Use these planning tiers, not guarantees. Quantization, context length, other
apps, and LM Studio runtime settings can change the result:

| Unified memory | Sensible starting range | Status |
| --- | --- | --- |
| 8 GB | 2–4B instruction model; short context | candidate only; expect tight headroom |
| 16 GB | 7–8B quantized instruction model | candidate only |
| 32 GB | 12–16B quantized instruction model | candidate only |
| 64 GB | 20–30B quantized instruction model, or more context | candidate only; test before relying on it |

Current LM Studio documentation uses IDs such as `ibm/granite-4-micro` and
`openai/gpt-oss-20b` in examples, but those are **LM Studio documentation
examples, not Quill benchmarks or endorsements**. Verify the exact ID in your
own `/v1/models` response. For a model that does fit, Quill's bounded
extraction request uses a five-minute timeout, up to 2,048 completion tokens,
and a 6,000-token chunk budget. A 16K context can be reasonable for a
large-model profile, but it is not required for every model or meeting.

Set context length in LM Studio's model-loader configuration before loading, or
with the CLI after substituting a locally listed identifier:

```sh
lms load "actual-model-id-from-lms-ls" --context-length 8192
```

Start at 8K on limited memory, confirm the synthetic request, then increase
only if the model still loads and responds reliably. Loading a larger context
allocates more memory; Quill does not change this setting for you.

Model storage is managed by LM Studio, not Quill. Use **My Models** to inspect
or choose its model directory; `lms ls` reflects that directory:

```sh
lms ls
lms ps
lms server status
```

If the `lms` command is unavailable, launch LM Studio once, then try again.
For a custom model location, choose it in LM Studio's **My Models** settings;
do not move model files while LM Studio has them loaded. Quill records only the
provider-reported model ID and runtime details in a generated Brief.

Useful failure meanings:

| Quill message | What to check |
| --- | --- |
| “Use a literal HTTP loopback endpoint” | use `http://127.0.0.1:1234`, not `localhost`, a LAN IP, HTTPS, or a path |
| server/model unavailable | start LM Studio's local server and load/select a listed model |
| local request timed out | use a smaller model/context, close memory-heavy apps, or retry later; recording remains independent |
| malformed structured output | retry with the same local model or choose a model that passes the synthetic check; review the transcript manually |

Primary references: [LM Studio local server](https://lmstudio.ai/docs/developer/core/server),
[OpenAI-compatible endpoints](https://lmstudio.ai/docs/developer/openai-compat),
and [LM Studio CLI/model-directory discovery](https://lmstudio.ai/docs/cli).

## 7. Upgrade and rollback

Before updating, stop any recording and wait for its transcription to finish.
Then:

```sh
cd "$HOME/Developer/quill-hebrew"
git pull --ff-only
swift build -c release
./scripts/install-app.sh
open -a Quill
```

The installer leaves `~/.config/quill/config.json` and recordings untouched.
When replacing an existing app, it archives the previous app as a zip in
`~/Applications/.quill-backups/`. It is safe to rerun the installer, though
each replacement creates another backup archive.

To roll back an app version, first quit Quill and unregister the current login
agent, preserve the current app somewhere safe, then expand the chosen archive
back into `~/Applications`:

```sh
"$HOME/Applications/Quill.app/Contents/MacOS/quill" install --uninstall
ditto -x -k "$HOME/Applications/.quill-backups/Quill-YYYYMMDD-HHMMSS.zip" "$HOME/Applications"
open -a Quill
```

Replace the placeholder archive name with one you inspected in Finder. This
does not roll back model downloads, configuration, or recordings; those remain
user-owned local data.

## 8. Troubleshooting checklist

1. **Build fails:** run `xcode-select --install`, reopen Terminal, then
   rerun `swift build -c release`.
2. **No feather:** run `open -a Quill`; then inspect
   `/tmp/quill.err.log` and the login registration command above. A running
   process alone does not prove the menu-bar item is visible.
3. **Hebrew MLX unavailable:** confirm Apple silicon, rerun `quill doctor`,
   and verify the Python and model paths in the Hebrew setup section. Do not
   switch an automatic/Hebrew meeting to Parakeet by accident.
4. **`ffmpeg` missing after login:** ensure `brew install ffmpeg` completed.
   Login agents can have a narrower PATH than an interactive shell; preserve
   the raw session tracks and inspect `transcribe.log` before retranscribing.
5. **Brief provider unavailable:** keep it disabled until the local synthetic
   check succeeds. It never blocks recording or transcription.

## Reusable Codex or Claude Code handoff prompt

Copy the following only when asking an assistant to help with setup or a code
change. It intentionally does not authorize recording or privacy changes:

```text
Work only in ~/Developer/quill-hebrew. Preserve all existing recordings,
~/.config/quill/config.json, LM Studio models/caches, unrelated models, and
unrelated files. Do not start or stop a recording, process any user recording,
grant or change macOS permissions, install/relaunch Quill, install/update LM
Studio, download/delete/move models, or edit the LaunchAgent unless I explicitly
ask in this message. Begin with read-only inspection and explain any action that
would affect persistent local state. Prefer documentation, tests, and isolated
synthetic fixtures. Never paste, upload, quote, or retain transcript/audio/note
content. If a requested step needs a permission prompt or would alter user data,
stop and ask me for confirmation.
```
