# Hebrew MLX setup

Quill's Hebrew engine runs entirely on your Apple-silicon Mac. It uses the
MLX-format model
[`mlx-community/ivrit-ai-whisper-large-v3-turbo-mlx`](https://huggingface.co/mlx-community/ivrit-ai-whisper-large-v3-turbo-mlx),
which is converted from the Hebrew
[`ivrit-ai/whisper-large-v3-turbo`](https://huggingface.co/ivrit-ai/whisper-large-v3-turbo)
model.

## Requirements

- macOS 15 or later for Quill's system-audio capture.
- An Apple-silicon Mac for MLX.
- Homebrew, Python 3, and an internet connection for this one-time setup.
- About 2 GB of free space for the model and Python environment.

## Recommended setup

From the repository root:

```sh
./scripts/install-hebrew-mlx.sh
quill doctor
```

The script installs `ffmpeg` through Homebrew, creates a dedicated virtual
environment at `~/.local/share/quill-hebrew/mlx-whisper`, downloads the model
to `~/Library/Application Support/quill-hebrew/models/`, and merges the local
engine paths into Quill's existing configuration without replacing unrelated
settings.

The setup selects Hebrew decoding by default because the model is trained for
mostly Hebrew audio. You can change the language in Quill's controls later.
The engine works offline after setup completes. Quill sends no recorded audio
to the model host or any transcription service.

## Manual setup

```sh
brew install ffmpeg
python3 -m venv "$HOME/.local/share/quill-hebrew/mlx-whisper"
"$HOME/.local/share/quill-hebrew/mlx-whisper/bin/pip" install --upgrade \
  "mlx-whisper" "huggingface_hub[hf_xet]"
"$HOME/.local/share/quill-hebrew/mlx-whisper/bin/huggingface-cli" download \
  --local-dir "$HOME/Library/Application Support/quill-hebrew/models/ivrit-ai-whisper-large-v3-turbo-mlx" \
  mlx-community/ivrit-ai-whisper-large-v3-turbo-mlx
```

Then set `mlx_python` and `mlx_model_dir` in `~/.config/quill/config.json` to
the two paths above and select `mlx-hebrew` in Quill's controls.

## Accuracy note

The model is optimized for mostly Hebrew audio. Its own model card says that
language detection and translation were degraded during training, so do not use
it as a translation engine. Keep the separate microphone and system tracks:
they provide more reliable results during overlapping speech than a single
mixed track.

## Licensing

The original ivrit-ai model is Apache-2.0 licensed. This project does not
include its weights. If you redistribute the weights yourself, include the
applicable model license and notices; see `THIRD_PARTY_NOTICES.md`.
